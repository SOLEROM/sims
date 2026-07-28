# System report — the sims simulation stack (ground truth)

*Last full revision: 2026-07-24. This document is the authoritative,
self-contained description of the whole system: what it is, how the running
simulation works end-to-end, what every shell script and every terminal tab is
responsible for, how to run and manage it, and the record of every
architecture decision (each with its detailed note where one exists). If this
document and reality disagree, fix one of them.*

---

## 1. What this system is

A **composable multi-vehicle drone-simulation stack** built from independent
docker layers:

* **PX4 v1.16 SITL + Gazebo Harmonic** — the autopilot and the physics engine
  (one frozen docker image, `px4-sitl-16`).
* **FlightGear 2020.3** — used NOT as a simulator but as a **drone-camera
  renderer**: physics stays in PX4/gz, and FlightGear draws what a camera on
  the vehicle would see, from a pose streamed in over UDP (`fgfs-base:24`).
* **QGroundControl** — the ground station: map, telemetry, mission upload,
  virtual joystick. A stock AppImage on the host, untouched.
* **An orchestrator** (`orch/v1/simrun.sh`) that boots N vehicles from a
  plain-text profile, one Terminator window per vehicle with one numbered tab
  per service, on top of per-vehicle network namespaces and a shared
  inter-vehicle bridge network.
* **Glue processes** ("taps") that close the gaps between the layers at
  runtime — a MAVLink→FlightGear pose bridge and a gz sensor keepalive —
  without modifying any layer image.

The result, for the default `px4-fg` profile: **fly the drone from
QGroundControl, and the FlightGear window shows the live camera view of that
flight**, computed by PX4's EKF over gz physics, rendered over per-station
satellite imagery of the real home location.

---

## 2. The running system at a glance (px4-fg)

```
                                    host network
 ┌────────────────────────────────────────────────────────────────────────────┐
 │  ┌───────────┐   MAVLink UDP: PX4 18570 → bcast 14550 → QGC                │
 │  │   QGC     │◄──────────────────────────────────────────────┐             │
 │  │  (6_qgc)  │──── commands / missions / virtual joystick ──►│             │
 │  └───────────┘                                               │             │
 │                     container px4-sitl-16 (--net=host)       │             │
 │  ┌───────────────────────────────────────────────────────────┴──────────┐  │
 │  │ PX4 v1.16 SITL  (pxh console = 2_pxh tab)                            │  │
 │  │   commander · EKF2 · navigator · …                                   │  │
 │  │   gz_bridge ◄──gz-transport──► gz-sim Harmonic (server -s = physics, │  │
 │  │                                 model x500_0, world default.sdf)     │  │
 │  │   mavlink #0  GCS      -u 18570 → 14550 (QGC autoconnect)            │  │
 │  │   mavlink #1  onboard  -u 14580 → 14540 (reserved — NEVER probe, §9.10)│ │
 │  │   mavlink pose (runtime-added) -u 14590 → 14591                      │  │
 │  └───────┬──────────────────────────▲────────────────▲───────────────────┘ │
 │          │ GLOBAL_POSITION_INT      │ 1 Hz hello +   │ held `gz topic -e`  │
 │          │ + ATTITUDE @30 Hz        │ rate requests  │ subscriptions on    │
 │          ▼                          │                │ imu/mag/baro/navsat │
 │  ┌───────────────────────────┐      │           (3_keepalive tab —        │
 │  │ pose_tap.py  (5_pose tab) ├──────┘            keeps gz sensors alive)  │
 │  │ MAVLink → fg_protocol     │                                            │
 │  └───────┬───────────────────┘                                            │
 │          │ 9-field datagram, UDP 15778                                    │
 │          ▼                                                                │
 │  ┌───────────────────────────────────────────┐                            │
 │  │ container fgfs_1  (4_fgfs tab)            │  props telnet TCP 15777    │
 │  │ FlightGear external-fdm renderer          │◄── fg_prop.py / wait_for / │
 │  │ camera window "FlightGear-1", ortho ground│    collect-logs            │
 │  └───────────────────────────────────────────┘                            │
 └────────────────────────────────────────────────────────────────────────────┘
```

The chain that makes it a camera: **QGC command → PX4 flight stack → gz
physics → EKF state → dedicated MAVLink stream → `pose_tap.py` →
`fg_protocol` UDP → FlightGear camera pose.** Every hop is observable through
a machine-readable side channel (uORB listeners, props telnet), never by
screenshot.

Boot it with:

```bash
./orch/v1/simrun.sh 1 --config px4-fg
```

and you get one Terminator window `agent-1` with the tabs
`1_px4 2_pxh 3_keepalive 4_fgfs 5_pose 6_qgc 7_debug` (§6.1).

---

## 3. Core architecture (the layer contract)

The full normative text is [`../CONVENTIONS.md`](../CONVENTIONS.md); this is
the summary of the model everything below assumes.

### 3.1 An agent is a netns group, not a container

One simulated vehicle ("agent") = a **group of docker containers sharing one
Linux network namespace**. A tiny sleeper container **`agent-$ID`** (the
"anchor", `orch/v1/agent_net.sh`) is created first and OWNS the namespace and
the vehicle's host-side port map; every service container joins it via
`--network container:agent-$ID`. Services can crash and restart freely
without tearing down the vehicle's networking — the anchor outlives them all.

### 3.2 `ID` is the only per-vehicle variable

The integer `ID` threads purely through the environment: simrun → window →
tab command (`export ID=<n>`) → `docker run --env ID`. It drives every
per-vehicle name: containers `<base>[-_]$ID`, window titles `FlightGear-$ID`,
named volumes `fgfs_home_$ID`.

### 3.3 Internal ports are identical across vehicles — on purpose

Isolation comes from the namespace, never from per-ID port renumbering.
Vehicle 1's FlightGear and vehicle 7's FlightGear both listen on 15777/15778
*inside their own netns*. Only the anchor's host-edge publish map is per-ID
(`AGENT_PUBLISH="1577%ID%:15777 1578%ID%:15778/udp"`). Never "fix" a port
collision by renumbering. Cross-vehicle traffic goes over the
shared docker bridge `sim-net` (172.31.0.0/16) that every anchor also joins.

### 3.4 Config layering

Precedence everywhere: **explicit env > env file > built-in default.**
`simrun.sh` auto-sources, in override order:

1. `orch/v1/env.list` — tracked, sim-wide (home lat/lon, camera defaults);
2. `orch/v1/profiles/<name>.env` — tracked, profile defaults;
3. `orch/v1/local.env` — **untracked**, per-STATION only (GPU backend,
   `QGC_CMD`, window placement). Created from `local.env.example` by
   `install.sh`, never clobbered.

### 3.5 The run-script contract

Every layer's `run.sh` is location-independent, reads all config from env
(documented in an `env.list.example`), runs `--rm` foreground so a tab shows
the live log and Ctrl-C kills the container, pre-removes its own leftover
name (tab restart = clean relaunch), supports `bash` as arg for a debug
shell, a dry-run knob, and a network-mode knob
(`bridge | host | container:<owner>`).

### 3.6 Profiles are plain-text tab manifests

A profile is nothing more than `orch/v1/profiles/terminator.run.<name>` —
one `tabname::command` line per service, `@once:` prefix for run-once
ground-station lines, plus an optional `<name>.env` with profile defaults.
Sequencing between tabs is done with `wait_for.sh` readiness probes, not
`sleep` chains.

---

## 4. Repository layout

| path | role |
|------|------|
| `CONVENTIONS.md` | the layer contract (normative version of §3) |
| `CLAUDE.md` | fast working context for an assistant session (rules, status, gotchas) |
| `orch/v1/` | orchestrator: simrun, anchors, tabs, probes, clean, taps, profiles (§5.1) |
| `fgear/craft_base_24/` | FlightGear drone-camera renderer layer (§5.2); `craft_base_20` is frozen history |
| `px4/px4_gazebo_16/` | **frozen** PX4 v1.16 + gz Harmonic SITL image + runner (§5.3); `px4_core_16` = no-gazebo variant (same image tag — the gazebo build is the one to use; last build wins) |
| `debug/` | run forensics: log collector, live arming/health decoder, investigation prompt (§5.4) |
| `design/` | this folder: the decision record — one note per non-obvious decision + this report |
| `offboards/v1/` | standalone 2-D target-tracking control playground (§5.5) — not part of the docker sim |
| `install.sh` | idempotent station setup: host tools, `local.env`, image builds + smoke (§8.1) |
| `ref/` | external reference links/notes (not load-bearing) |
| `qGr.md` | legacy scratch of QGC apt deps — superseded by `install.sh` |

---

## 5. The layers in detail — every shell script's responsibility

### 5.1 `orch/v1` — orchestration

| script | responsibility |
|--------|----------------|
| `simrun.sh` | The entry point: `simrun.sh N --config <profile>` (default `px4-fg`). Tears down the previous run (`clean.sh`, skip with `--no-clean`), sources the env layers (§3.4), splits the manifest into per-vehicle vs `@once:` lines, creates the bridge net + one anchor per ID (unless `SIM_NO_ANCHOR=1`), then opens ONE Terminator window per vehicle titled `agent-<ID>` whose tabs are the manifest lines numbered `<seq>_<name>`, each prefixed `export ID=<n>;`. `@once:` tabs join agent-1's window, continuing its numbering. `SIM_DRYRUN=1` prints the whole plan (including every rendered tab line) and touches nothing. |
| `agent_net.sh` | `up <ID> / down <ID> / status`: the per-vehicle netns **anchor** `agent-$ID` — a `sleep infinity` container (default image ubuntu:24.04) that owns the namespace and the host port map (`AGENT_PUBLISH`, `%ID%` token), and joins `SIM_NET`. Idempotent: `up` recreates. |
| `term_tabs.sh` | Terminator window builder: `-t title -d workdir -f manifest` of `name::cmd` lines → generates a Terminator layout config with one wrapper script per tab. Each wrapper sets the tab title, runs the command in the caller's environment **with a TTY preserved** (so `docker -it` works), and on command exit drops into a titled interactive bash in the same cwd — a tab never closes on you, and a tab whose command was `cd debug && ls` becomes a ready shell there. |
| `wait_for.sh` | Readiness probes replacing `sleep` sequencing (1 s poll, timeout → exit 1): `container <name>` (docker state Running), `tcp <host:port>`, `fg-telnet [port]`, and `fg-props [port]` — a **protocol-level** probe that requires an actual props-telnet `get` answer. Use `fg-props` through docker **published** ports: docker-proxy accepts TCP before the backend listens, so a plain connect false-positives there. |
| `clean.sh` | Teardown by the naming contract: removes every container matching `^(agent|fgfs|px4-sitl)[-_]<ID>$` (bases overridable via `CLEAN_PATTERNS`; optional single-ID scope; `-n` dry-run) and, on a full clean, the `sim-net` bridge. Named volumes (FlightGear NavCache `fgfs_home_$ID`) are deliberately LEFT; `docker volume rm` forces a cache rebuild. |
| `sensor_keepalive.sh` | **Keeps the gz sensors publishing** (px4-fg tab `3_keepalive`). The frozen image's gz-sim 8.14 computes/publishes a sensor only while its publisher sees subscribers, and PX4's own `gz_bridge` subscriptions are not counted (upstream regression) — so this script holds one `docker exec gz topic -e` subscription per sensor topic (imu, magnetometer, air_pressure, navsat; `KEEP_TOPICS` overrides). v2.1 semantics, each learned the hard way (§9.9): per-topic monitoring and re-attach (never drop-all — a zero-subscriber window can PERMANENTLY sever PX4's own feed), epoch tracking via the gz **server pid**, and a full subscriber-slate wipe only in the pxh-restart DOWN window (killing a subscriber while a sim runs is itself a severance trigger). Knobs: `KEEP_CONTAINER/GZ_WORLD/GZ_MODEL/TOPICS/POLL/WAIT/TRIES`. |
| `pose_tap.sh` | **The physics→camera bridge keeper** (px4-fg tab `5_pose`). Loop: wait for the PX4 container → ensure a **dedicated MAVLink instance** exists inside it (runtime `docker exec … px4-mavlink start -x -u 14590 -r 4000000 -m onboard -o 14591`; readiness = the port actually bound in `/proc/net/udp`, checked first so a live instance isn't "re-started" into scary console noise) → run `tools/pose_tap.py`. The tap exits rc 2 after `POSE_IDLE_EXIT` (20 s) of MAVLink silence — e.g. after a pxh Ctrl-C — and the loop re-ensures the instance, so the bridge self-heals across sim restarts. Knobs: `POSE_CONTAINER/MAV_LOCAL/MAV_PORT/IDLE_EXIT/WAIT/TRIES/TAP_ARGS`. |
| `tools/pose_tap.py` | The bridge itself, **stdlib-only** (§9.11): binds UDP 14591; from that same socket (any other source socket would steal the PX4 partner latch, §9.10) sends 1 Hz heartbeats plus `SET_MESSAGE_INTERVAL` requests (GLOBAL_POSITION_INT + ATTITUDE at `--rate-hz` 30) to the dedicated instance; parses MAVLink v1/v2 frames with hand-coded MCRF4XX CRC + per-message crc_extra (wrong seed = 100 % rejects = loud stall, never silent garbage); converts each fix into the 9-field `fg_protocol` datagram (degrees, **feet AMSL**, nadir cam pitch −85 by default) → UDP 15778, throttled to `--max-hz` 60. Yaw source: GLOBAL_POSITION_INT heading, ATTITUDE-yaw fallback. `--selftest` = 14 offline checks incl. a fake-PX4→tap→fake-FG loopback; `--idle-exit`, `--north-up/--north-trim`, `--cam-pitch`, `--flat`, `--alt-offset-m` etc. — see `--help`. |
| `tools/validate.sh` | Staged orchestrator validation: static (shellcheck-ish + `pose_tap.py --selftest`) → simrun dry-run plan asserts (exact rendered tab lines for both profiles) → real anchor lifecycle → `wait_for` probe behavior (incl. the keepalive/pose-tap fast-timeout give-up paths) → clean dry-run → `--live`: boots 2 real fg-demo vehicles headless, asserts each is circling near home via published props telnet, tears down, asserts nothing left. **35/35 as of 2026-07-23.** |
| `env.list`, `profiles/*`, `local.env(.example)` | the config layers of §3.4 and the two shipped profiles of §6. |

### 5.2 `fgear/craft_base_24` — the FlightGear drone-camera renderer

Two modes via `FG_MODE`:

* `standalone` — plain FlightGear flying itself (scenery checks, exploring).
* `external-fdm` — **the important one**: FlightGear does NO physics. The
  pose streams IN over UDP 15778 (`protocol/fg_protocol.xml`: 9
  tab-separated `%f` fields — cam-pitch-off, cam-roll-off, heading, pitch,
  roll, lat, lon, **alt-ft**, view-heading-off) and FG renders the camera
  view. Field 9 on this build: `screen_up_azimuth = heading − offset`
  (slope −1) — send 0 for heading-up/FPV, `heading − TRIM` to pin north-up.
  N instances = N independent drone cameras, isolated by netns.

| file | responsibility |
|------|----------------|
| `run.sh` | host-side docker runner (contract §3.5): `ID`, `FG_NET` network mode, `FGFS_GPU` backend select, xauth, per-ID NavCache volume `fgfs_home_$ID` (~166 MB, first run only), `FG_ASSETS_DIR` live-editable mounts (`Orthophotos/ Models/ Objects/ Nasal/ Protocol/ AI/`). |
| `fgfs_runner.sh` | in-container dual-mode launcher; every knob env-driven (see `env.list.example` — the complete knob list with defaults). |
| `Dockerfile.base` / `build.sh` | the generic `fgfs-base:24` image (ubuntu 24.04 + FlightGear PPA + xvfb for headless CI + baked protocol/Nasal hooks); optional build args `SCENERY_TILES` / `AIRCRAFT_ZIPS`. |
| `protocol/fg_protocol.xml` | the 9-field UDP pose input definition (baked; overridable). |
| `nasal/addobj.nas` | runtime object placement + **ortho-ground auto-place** from `/ortho/*` props once scenery is loaded (§9.13). |
| `tools/fg_tiles.py` | exact-simgear SGBucket tile math (+ selftests) — trust it over ad-hoc tile scripts. |
| `tools/gen_orthophotos.py/.sh` | satellite-imagery generator: home ortho quad + photoscenery tiles, aspect-matched ArcGIS fetch with an extent-honesty probe (§9.14). Run per station; output is untracked. |
| `tools/gen_objects.py/.sh` | `objects.json` → per-tile `.stg` tree + ground-station `.kml`. |
| `tools/feed_fdm.py` | reference `fg_protocol` sender (circling fake flight) — validation and the template for any new pose bridge. |
| `tools/fg_prop.py` | props-telnet get/set — THE verification tool; everything observable lives in the property tree on 15777. |
| `tools/validate.sh` | staged: static → tile selftests → generators → dry-run → `--build` → `--image` → `--live` headless end-to-end (xvfb + software GL + UDP pose + props asserts). **29/29 + live as of 2026-07-22.** |

Render rules that cost real debugging time (details in the layer readme):
ortho ground **requires hardware GL** (`FGFS_GPU=intel|host`; llvmpipe is
slow AND never draws it), the ground quad is placed at **runtime** (static
`.stg` never renders on this build), its elevation must sit just below the
landed camera, the draped texture's 90° rotation fix is baked into the `.ac`
UVs, the window is square on purpose, and instances get per-ID window titles
so capture tooling targets the right one.

### 5.3 `px4/` — the frozen autopilot + physics layer

**FROZEN by decision** (§9.7): used exactly as-is, never edited, never
rebuilt with changes. `px4_gazebo_16/Dockerfile.px4-sitl-gazebo` builds
`px4-sitl-16`: PX4-Autopilot v1.16 compiled for SITL plus Gazebo Harmonic
(gz-sim 8.14.0 / gz-transport 13.5.0 at current build date).

`px4_gazebo_16/run.sh` — dual-purpose: first call `docker run`s the
container (name `px4-sitl-16`, `--net=host`, X11 socket + xauth mounts, bind
mount `./logs` → the SITL log dir); a second call `docker exec`s a bash into
it. The image's CMD is plain bash — the sim is started manually (or by the
`2_pxh` tab) via `./runGzPX4.sh` inside, which launches PX4 with
`PX4_SIM_MODEL=gz_x500`; PX4's rcS then starts the gz **server** (physics)
and — only when `HEADLESS` is unset in its env — a gz GUI client (§9.8).

The world (`default.sdf`) spawns model `x500_0` at Zurich Irchel
(47.397971, 8.546164, ground 0 m AMSL). Stock rcS MAVLink instances:
GCS `-u 18570` broadcasting to 14550 (QGC autoconnect), onboard
`-u 14580 -m onboard -o 14540`, payload 14280→14030, gimbal 13030→13280.

Everything the profile needs beyond stock behavior is **injected at runtime
from outside** — `docker exec -e HEADLESS=…`, `docker exec px4-mavlink
start …`, `docker exec gz topic -e …` — which is the load-bearing pattern
that keeps the layer frozen (§9.7).

### 5.4 `debug/` — run forensics

| script | responsibility |
|--------|----------------|
| `collect-logs.sh` | Read-only snapshot of a run into `/tmp/sims-logs-<ts>/` (+ `.tgz`): `docker logs` + `docker inspect` of every sim container, best-effort FlightGear props per live renderer, the PX4 flight-log bind mount (ulogs), system/env state, and a `MANIFEST.txt` index. **Run it BEFORE any relaunch** — `simrun.sh` auto-cleans, which deletes the containers and their logs. `--id N` scopes to one vehicle (`px4-sitl-16` is special-cased: its 16 is a version, not an ID). |
| `px4-health.sh` | LIVE decoder for "why is arming denied right now": queries the running container via read-only uORB listeners (`vehicle_status`, `failsafe_flags`, `health_report`), decodes the bitmasks + per-mode requirement flags, prints the actual blocker for the current mode and which modes could arm, plus a **sensor-feed freshness section** (two timestamp samples per sensor; FROZEN/NEVER = severed gz feed, fix printed inline). Exists because PX4's detailed check failures only go out via MAVLink *events* (QGC shows them; the pxh console never does). |
| `debugPrompt.md` | paste-into-a-fresh-assistant forensics prompt for a collected bundle: system model, source map, bundle layout, known-failure checklist, and the required three-part evidence-cited report format. |
| `tools/validate.sh` | staged self-test using a scratch container. **13/13.** |

### 5.5 `offboards/v1` — control-algorithm playground (not docker)

A self-contained 2-D **target-tracking simulator** (`drone_tracker` python
package + notebooks): moving target → simulated bearing/range perception →
pluggable controllers (P, PID, pure-pursuit) → FCU-style rate limits, with
tracking metrics. Runs in its own venv (`pip install -e .`, `drone-sim`
CLI, Jupyter notebooks). It shares no runtime with the docker sim — it is
where control ideas are prototyped before they become an offboard companion
(§10).

### 5.6 `install.sh` — station setup

Idempotent: (1) host tools via apt — docker, terminator, python3 (+PIL,
numpy for the generators), X11 helpers, QGC AppImage runtime deps (gstreamer,
libfuse2t64, xcb libs) + dialout group; (2) `orch/v1/local.env` from the
example, never clobbered; (3) docker images `fgfs-base:24`, `px4-sitl-16`,
anchor `ubuntu:24.04`; (4) image smoke checks. `--check` reports only;
`--no-apt/--no-px4/--no-fgfs/--force-images` scope it. The PX4 image build
is the heavy step (clones PX4 v1.16 + submodules, compiles SITL+gz in
docker: tens of minutes, multi-GB).

---

## 6. Profiles — what each shell (tab) is responsible for

### 6.1 `px4-fg` (default) — the full stack, single vehicle

Single vehicle by design for now: the frozen px4 layer predates the
conventions (hardcoded name, `--net=host`), so this profile runs on the
**host network** with `SIM_NO_ANCHOR=1` (no anchors; fg-demo demonstrates the
multi-vehicle model). Profile env aligns FlightGear's home + ortho ground
with the px4 world's Zurich spawn (`FG_HOME_*`, `FG_ORTHO_ELEV_M=0.2`,
`FG_ASSETS_DIR`).

| tab | command (essence) | responsible for |
|-----|-------------------|-----------------|
| `1_px4` | `mkdir -p logs && ./px4/px4_gazebo_16/run.sh` | **The vehicle container's lifetime.** Pre-creates the `logs/` bind-mount source as the user (dockerd would otherwise try to mkdir it and fail), then runs the frozen container in the foreground — the tab IS the container's bash. Ctrl-D/exit here kills the whole vehicle. |
| `2_pxh` | `wait_for container px4-sitl-16 && docker exec -it -e HEADLESS=… px4-sitl-16 ./runGzPX4.sh` | **The sim's lifetime.** Starts PX4 + gz physics; the tab is the **pxh console** (`commander takeoff`, `param set`, `listener …`). `HEADLESS` is injected here per `PX4_HEADLESS` (default 1 = no gz GUI window, §9.8). Ctrl-C stops the sim but keeps the container; rerun `./runGzPX4.sh` to restart — then check `debug/px4-health.sh` (§8.6 restart caveat). |
| `3_keepalive` | `./orch/v1/sensor_keepalive.sh` | **Keeping the vehicle's sensors alive.** Holds gz subscriptions on all four sensor topics; without this tab accel/gyro/compass randomly never publish → EKF dead → nothing can arm (§9.9). Must stay running for the whole run. |
| `4_fgfs` | `wait_for container … && FG_MODE=external-fdm FG_NET=host ./fgear/craft_base_24/run.sh` | **The camera.** The FlightGear renderer window (`FlightGear-1`), listening for pose on UDP 15778, controllable/verifiable over props telnet 15777, drawing the per-station ortho satellite ground. |
| `5_pose` | `./orch/v1/pose_tap.sh` | **The physics→camera link.** Dedicated MAVLink instance (14590→14591) + `pose_tap.py` → `fg_protocol` → UDP 15778. This is the tab that makes flying in QGC move the FG camera (§9.10). Extra tap flags (e.g. `--north-up`) via `POSE_TAP_ARGS` in `local.env`. |
| `6_qgc` (`@once`) | `${QGC_CMD:-echo …}` | **The ground station.** Launches the QGC AppImage pointed to by `QGC_CMD` (`local.env`); QGC autoconnects by listening on UDP 14550, where the stock rcS broadcasts heartbeats. Prints a hint instead if `QGC_CMD` is unset. |
| `7_debug` (`@once`) | `cd debug && ls` | **A ready forensics shell.** The tab wrapper drops into an interactive bash in `debug/` — `./px4-health.sh` when arming misbehaves, `./collect-logs.sh` before any relaunch. |

### 6.2 `fg-demo` — the multi-vehicle renderer demo

Self-contained (only needs `fgfs-base:24`): per vehicle a renderer plus a
fake circling flight, each vehicle in its own anchored netns; host reach via
the anchors' published ports (`1577<ID>` telnet, `1578<ID>` pose UDP).

| tab | responsible for |
|-----|-----------------|
| `1_fgfs` | the renderer, joined to `container:agent-$ID` |
| `2_feed` | waits for the renderer to actually answer props (`wait_for fg-props 1577$ID`), then streams a circling pose to `1578$ID` (`feed_fdm.py`, home from `FG_HOME_*`) |
| `3_info` (`@once`) | prints the port map + a copy-paste verification command |

Verify any vehicle from the host:
`python3 fgear/craft_base_24/tools/fg_prop.py --port 1577<ID> get /position/latitude-deg`.

---

## 7. Network & port map (px4-fg, host network)

| port | proto | listener | sender | purpose |
|------|-------|----------|--------|---------|
| 14550 | UDP | QGC | PX4 mavlink #0 (from 18570, broadcast) | ground-station link; QGC autoconnect |
| 18570 | UDP | PX4 mavlink #0 | QGC | PX4 side of the GCS link |
| 14580 → 14540 | UDP | (reserved) | PX4 mavlink #1 "onboard" | stock offboard link. **Do not bind, probe, or send to either port** — the partner latch (§9.10) means one stray packet hijacks the stream until PX4 restarts. Reserved for a future offboard companion with its own discipline. |
| 14280 → 14030 | UDP | — | PX4 payload instance | stock, unused here |
| 13030 → 13280 | UDP | — | PX4 gimbal instance | stock, unused here |
| 14590 | UDP | PX4 pose instance (runtime-added) | `pose_tap.py` (hellos + rate cmds, always from its rx socket) | pose-tap control side |
| 14591 | UDP | `pose_tap.py` | PX4 pose instance (`-o`) | GLOBAL_POSITION_INT + ATTITUDE @30 Hz |
| 15778 | UDP | FlightGear generic input | `pose_tap.py` / `feed_fdm.py` | `fg_protocol` 9-field pose |
| 15777 | TCP | FlightGear props telnet | `fg_prop.py`, `wait_for.sh`, `collect-logs.sh` | property tree: verification + runtime control (`/ortho`, `/addobj`) |
| 5503 | UDP | FlightGear native-fdm | (legacy-compat) | normally unused |

Non-UDP link: PX4 `gz_bridge` ⇄ gz-sim over **gz-transport** (in-container
topics `/world/default/model/x500_0/link/base_link/sensor/...` — the ones the
keepalive holds).

fg-demo host edges (per vehicle, via anchor publish): `1577<ID>`→15777/tcp,
`1578<ID>`→15778/udp; anchors also join bridge `sim-net` 172.31.0.0/16.
Rule of thumb: **inside a netns, ports are always the defaults; per-ID
numbers exist only at the host edge.**

---

## 8. How to run and manage

### 8.1 Station setup (once)

```bash
./install.sh --check      # report what's missing, change nothing
./install.sh              # install tools, write local.env, build images (PX4 build = tens of minutes)
```

Then edit `orch/v1/local.env`: set `QGC_CMD` to your QGC AppImage, and
`FGFS_GPU=intel` (or `host`) on a hybrid-GPU laptop — the ortho ground needs
hardware GL. For the px4-fg profile generate the satellite ground once per
station (~1 min, needs network; output untracked):

```bash
FG_HOME_LAT=47.397971 FG_HOME_LON=8.546164 \
  ./fgear/craft_base_24/tools/gen_orthophotos.sh --assets fgear/craft_base_24/assets
```

For stick-flying in QGC, enable once per station: QGC → Application
Settings → Fly View → **Virtual Joystick** (QGC persists it in its own ini).

### 8.2 Launch / plan / teardown

```bash
./orch/v1/simrun.sh 1 --config px4-fg     # the full stack (default profile, N=1)
./orch/v1/simrun.sh 3 --config fg-demo    # 3 renderer-demo vehicles
SIM_DRYRUN=1 ./orch/v1/simrun.sh …        # print the exact plan, touch nothing
./orch/v1/simrun.sh … --no-clean          # keep the previous run's leftovers
./orch/v1/clean.sh [-n] [ID]              # teardown (dry-run / one vehicle)
```

Every launch auto-cleans first — a run is always fresh. **If the previous
run misbehaved, collect logs BEFORE relaunching** (§8.5).

### 8.3 Flying (px4-fg)

Wait for the boot to settle (keepalive tab says "all topics held", pxh says
"Ready for takeoff!"), then any of:

* **QGC**: click-to-fly / Takeoff slider (AUTO modes need no sticks), or
  upload a mission and Start, or hand-fly with the Virtual Joystick;
* **pxh tab**: `commander takeoff`, `commander land`, etc.

Plain `commander arm` in MANUAL mode is denied without stick input — that is
correct behavior, not a health failure (§9.15). The FlightGear window
follows the flight via the pose tap; nothing to do there.

### 8.4 Verifying — machine-readable, never screenshots

```bash
python3 fgear/craft_base_24/tools/fg_prop.py get /position/latitude-deg   # FG pose
./debug/px4-health.sh                                    # arming/EKF/sensor-feed truth
# pxh tab: listener vehicle_global_position ; listener telemetry_status
```

`fg_prop.py` (default port 15777, `--port 1577<ID>` for fg-demo) reads the
same property tree the renderer renders from; `px4-health.sh` reads the same
uORB state the commander decides from. MAVLink link diagnosis: use
`px4-listener telemetry_status` — `mavlink status` prints to the SERVER
console (the pxh tab), not to a `px4-mavlink` client call.

### 8.5 Debugging a bad run

```bash
./debug/collect-logs.sh          # FIRST — relaunching destroys the evidence
./debug/px4-health.sh            # if the vehicle won't arm / won't move
```

Then either investigate the bundle yourself (`MANIFEST.txt` first) or paste
`debug/debugPrompt.md` + the bundle path into a fresh assistant session.
Terminator tab scrollback is NOT in the bundle (known limit) — if a tab's
`wait_for` timed out, the evidence is only in that tab.

### 8.6 Mid-run lifecycle

* **Restart the sim, keep the container**: Ctrl-C in `2_pxh`, rerun
  `./runGzPX4.sh`. The keepalive detects the down window, wipes the
  subscriber slate, and re-attaches for the new epoch; the pose tap idle-exits
  and re-ensures its instance. **Caveat (accepted risk):** a pxh restart
  inside a lived-in container is not fully reliable on this gz build — after
  any restart run `debug/px4-health.sh`; if a sensor feed shows FROZEN/NEVER,
  restart pxh again or relaunch the run. Fresh `simrun.sh` boots have been
  reliable every time.
* **Restart a service tab**: just rerun its command — every run script
  pre-removes its leftover container name; tab restart = clean relaunch.
* **Kill a vehicle / everything**: `clean.sh [ID]` / `clean.sh`.

### 8.7 Validation

```bash
./orch/v1/tools/validate.sh --live            # 35/35: orchestrator + taps + live 2-vehicle boot
./fgear/craft_base_24/tools/validate.sh --all # 29/29 + live headless renderer end-to-end
./debug/tools/validate.sh                     # 13/13
python3 orch/v1/tools/pose_tap.py --selftest  # 14 offline bridge checks
```

Every layer's validation is staged (static → selftests → dry-run asserts →
build → smoke → live headless) and asserts only through machine-readable
channels — the live stages need no display and no GPU.

### 8.8 Where configuration lives

| what | where |
|------|-------|
| sim-wide defaults (home, camera) | `orch/v1/env.list` (tracked) |
| profile behavior (`SIM_NO_ANCHOR`, `PX4_HEADLESS`, px4-fg home/ortho alignment, `AGENT_PUBLISH`) | `orch/v1/profiles/<name>.env` (tracked) |
| station-only knobs (`FGFS_GPU`, `QGC_CMD`, `POSE_TAP_ARGS`, `PX4_HEADLESS=0` for the gz GUI) | `orch/v1/local.env` (untracked) |
| every FlightGear-layer knob + default | `fgear/craft_base_24/env.list.example` |
| tap/keepalive knobs (`POSE_*`, `KEEP_*`) | script headers (defaults safe with empty env) |

---

## 9. Architecture decision record

Chronological-ish; ★ = has its own detailed note in this folder.

1. **Layers, not a monolith.** Autopilot, renderer, orchestration, forensics
   are independent docker/script layers composed by profiles; any layer is
   reusable alone. Consequence: all integration happens at runtime seams
   (env, UDP, docker exec), never by cross-layer code edits.
2. **Agent = netns group with a sleeper anchor** (`agent-$ID`): services
   crash/restart without killing the vehicle's networking; published ports
   are declared once, by the anchor. Rejected: "first heavy container owns
   the netns" — killing it takes the vehicle down.
3. **`ID` is the only per-vehicle variable**, threaded purely through env.
   Everything per-vehicle (names, titles, volumes, host ports) derives from
   it; scripts hard-fail fast when it's required and unset.
4. **Identical internal ports everywhere; per-ID only at the host edge.**
   Isolation by namespace, never renumbering (§3.3).
5. **Profiles are plain-text tab manifests** rendered into one Terminator
   window per vehicle. A profile is a text file; the orchestrator has no
   per-profile code. `@once:` marks ground-station lines.
6. **Readiness probes over sleep chains** (`wait_for.sh`), with a
   protocol-level `fg-props` probe because docker-proxy accepts TCP before
   the backend listens (plain connect false-positives on published ports).
7. **The px4 layer is FROZEN; every fix goes AROUND it via runtime
   injection** — `docker exec -e` for env (headless), `docker exec
   px4-mavlink start` for extra links (pose tap), `docker exec gz topic -e`
   for subscriptions (keepalive). One pattern, three users; the image and
   its scripts are never edited.
8. ★ **`PX4_HEADLESS` (default 1)** — PX4's rcS spawns a gz GUI client when
   `HEADLESS` is unset and the container has a DISPLAY; physics is the gz
   server either way. Default = physics only (QGC is the eyes); `=0` pops
   the GUI for world/model eyeballing.
   → [`px4-fg-gazebo-headless.md`](./px4-fg-gazebo-headless.md)
9. ★ **gz sensor keepalive** — this gz-sim 8.14 publishes a sensor only
   while a *counted* subscriber exists, PX4's own bridge isn't counted, and
   which sensors lose the race varies per run; worse, a zero-subscriber
   window can permanently sever PX4's feed, and killing subscribers mid-run
   is itself a trigger. Hence keepalive v2.1: hold ALL four topics,
   per-topic re-attach, epoch-aware cleanup only in the down window.
   → [`px4-fg-gz-sensor-keepalive.md`](./px4-fg-gz-sensor-keepalive.md)
10. ★ **Dedicated MAVLink instance per consumer — never share PX4's stock
    UDP links.** PX4 v1.16's UDP mavlink latches its partner to the FIRST
    packet source it ever hears (even overriding `-o`) and never re-learns;
    any stray probe of 14580/14540 steals the stream until PX4 restarts.
    The pose tap therefore gets a private 14590→14591 instance, created at
    runtime; all of the tap's TX originates from its bound rx socket so the
    latch can never wander. → [`px4-fg-pose-tap.md`](./px4-fg-pose-tap.md)
11. **Layer tools are stdlib-only python.** The pose tap hand-codes the
    three MAVLink messages it needs (MCRF4XX CRC + crc_extra) instead of
    depending on pymavlink/MAVSDK — the template stays dependency-free, and
    a wrong CRC seed fails loudly (100 % rejects), never silently.
12. **FlightGear is a renderer, not a simulator.** Physics authority is
    PX4/gz; FG consumes pose over the 9-field `fg_protocol` (deg/feet-AMSL,
    explicit camera offsets, view-azimuth field with the measured slope −1
    convention). The EKF estimate — what the drone believes, what QGC
    shows — is deliberately the camera's pose source, not gz ground truth.
13. **Ortho satellite ground, the hard-won rules**: placed at RUNTIME via
    Nasal (static `.stg` flat quads never draw on this build), hardware GL
    required (llvmpipe: slow AND no ground), elevation just below the landed
    camera, the 90° draped-texture rotation fixed in the generated `.ac`
    UVs, square window on purpose. (Layer readme "render lessons".)
14. ★ **Aspect-matched imagery fetch**: the ArcGIS export endpoint silently
    re-aspects mismatched extents (a square request for a non-square bbox
    stretches latitude — ~50 m ground error); the generator computes pixel
    height from the bbox aspect and probes the provider's honesty
    (`f=json`) once per run.
    → [`fg-ortho-arcgis-reaspect.md`](./fg-ortho-arcgis-reaspect.md)
15. ★ **Arming truth**: "Resolve system health failures first" in MANUAL
    mode usually means *no stick input exists*, not ill health — fly AUTO
    (takeoff/mission), enable QGC's Virtual Joystick, or use an offboard
    path; `debug/px4-health.sh` decodes the real blocker, since PX4 only
    reports details via MAVLink events.
    → [`px4-fg-arming-manual-control.md`](./px4-fg-arming-manual-control.md)
16. **Verification through machine-readable side channels only** (props
    telnet, uORB listeners, logs) — never screenshots; live validation
    stages run headless so CI needs no display/GPU.
17. **Forensics are read-only and precede relaunch** (`collect-logs.sh`);
    the auto-clean that makes runs reproducible is also what destroys
    evidence, so the collector is the mandatory first move on any bad run.

---

## 10. Known limits & accepted risks

* **px4-fg is single-vehicle** — the frozen px4 layer predates the contract
  (fixed name, host net). Multi-vehicle PX4 requires bringing that layer up
  to §3 (ID-suffixed name, netns-owner mode) — planned, not scheduled.
* **No offboard companion yet** — programmatic OFFBOARD flight (setpoint
  streaming, scripted missions) is future work; when it comes, it must get
  its OWN MAVLink instance (decision 10). `offboards/v1` is its algorithm
  sandbox.
* **pxh-restart roulette** (decision 9 / §8.6): restarts inside a lived-in
  container can leave one sensor unserved; the documented check-and-retry is
  the accepted mitigation. Fresh boots are reliable.
* **A single keepalive holder death** opens a ≤2 s one-topic window
  (`KEEP_POLL`); remaining killers are container-level events that take the
  vehicle down anyway.
* **Terminator tab scrollback is not captured** by the log collector — a
  failed tab command lives only in the tab. Teeing tab output is the known
  next improvement (needs a plan).
* **Container-name collisions**: any other stack on the same host using the
  bases `agent|fgfs|px4-sitl` collides with this one — don't run both, or
  override `CLEAN_PATTERNS`/`COLLECT_PATTERNS`.
* **Flight-follow end-to-end demo**: pose propagation (PX4 EKF coords →
  FG camera, live updates, ≤3e-6° agreement) is live-verified; the full
  "QGC takeoff visibly moves the camera" pass rides on a run with healthy
  arming (decision 9 fixed the blocker).
* **Ortho assets are per-station and untracked** — a fresh clone renders
  void ground at the px4-fg home until `gen_orthophotos.sh` runs (§8.1).
* **QGC Virtual Joystick is a per-station QGC setting** the sim never
  touches; automating it is proposed but not approved.
