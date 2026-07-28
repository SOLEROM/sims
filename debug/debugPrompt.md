# sims debug prompt — investigate a collected run

> **Paste this whole file to a fresh Claude Code session, then fill in the
> INPUTS at the top.** Your job is to read a log bundle produced by
> `debug/collect-logs.sh`, find the root cause of an observed misbehavior, and
> propose concrete fixes (with file + line references). This file gives you the
> system model, the source map, the bundle layout, the verification channels,
> and the known failure modes so you can investigate efficiently.

---

## INPUTS  (fill these in)

- **LOG_FOLDER:** `<path to the collected folder or .tgz>`
  (a `sims-logs-<ts>/` dir or tarball from `debug/collect-logs.sh`)
- **OBSERVED_BEHAVIOR:** `<what went wrong — what you saw vs. expected>`
- **WHEN / WHICH VEHICLE (optional):** `<approx time into the run, vehicle ID(s), profile used>`

---

## Your task

1. Orient: read `MANIFEST.txt` + `system/` to learn which profile ran (env
   files), the git rev, and which containers existed (Up vs Exited).
2. Reproduce the timeline of the symptom from the **per-container console
   logs** (`docker/`) and the state snapshots (`fg/`, `px4/`, `inspect/`).
3. Form a **ranked set of root-cause hypotheses**, each backed by specific
   evidence (cite repo `file:line` and the exact log line).
4. Propose **concrete fixes** (which file, what change, why) and a way to
   **verify** each (a validate.sh assert, a props-telnet check, a fresh-run
   metric).
5. Be honest about uncertainty: if the logs don't show the cause, say what's
   missing and what extra logging/repro would pin it down.

Deliver a **final report in exactly three parts** (see "Final report" below):
(1) what was wrong + how to fix it, (2) sims source-code suggestions,
(3) log-collection improvements for next time / whether to re-collect.

This is **read-only forensics** — do not start/stop the sim or mutate the repo
unless the user explicitly asks you to apply a fix.

---

## System model (what you're debugging)

This repo is a reusable **simulation-layer template** (distilled from a
production multi-drone sim). `./orch/v1/simrun.sh N --config <profile>` boots N
"vehicles". A vehicle is a *group of docker containers sharing one Linux
network namespace*, keyed only by the integer **`ID`**:

- `agent-$ID` — tiny anchor container that **owns the netns** + the host port
  map (`AGENT_PUBLISH`, `%ID%` token); services join with
  `--network container:agent-$ID`. Internal ports are IDENTICAL across
  vehicles; only the anchor's host edge is per-ID.
- One Terminator window per vehicle titled `agent-<ID>`, tabs `<seq>_<name>`
  from the profile manifest; `@once:` tabs (ground station etc.) join
  agent-1's window. Each tab `export ID=<n>` before its command.
- Env layering (later overrides): `orch/v1/env.list` < `profiles/<name>.env` <
  `orch/v1/local.env` (untracked, station-local). All three are in
  `system/env/` in the bundle — that tells you which profile/knobs ran.
- **Every launch first runs `clean.sh`** (fresh run) unless `--no-clean`.

Shipped profiles:

- **fg-demo** (multi-vehicle): per vehicle a FlightGear drone-camera renderer
  (`fgfs_$ID`, external-fdm) + a circling `feed_fdm.py` pose feeder.
  Pose in: `fg_protocol` UDP 15778 (host edge `1578<ID>`); state out: props
  telnet 15777 (host edge `1577<ID>`).
- **px4-fg** (default, SINGLE vehicle, `SIM_NO_ANCHOR=1` → host network):
  frozen PX4 v1.16 + gz Harmonic container `px4-sitl-16` + an FG renderer.
  Tabs: `1_px4` = the container's shell (the frozen image's CMD is bash),
  `2_pxh` auto-starts PX4+gz via `docker exec ./runGzPX4.sh` (pxh console),
  `3_keepalive` holds gz subscriptions on the four sensor topics (see the
  px4-fg checklist below), then renderer / QGC / debug tabs — for exact
  numbering read `profiles/terminator.run.px4-fg` (the code wins). QGC
  autoconnects: stock
  rcS broadcasts MAVLink heartbeats to UDP **14550** on the host net.
  **Known gap:** no gz→`fg_protocol` "pose tap" yet, so FG legitimately sits
  at home over the ocean/ortho — that alone is NOT a bug.

---

## Source code map

```
CONVENTIONS.md               the layer contract (agent model, ID, naming, probes)
orch/v1/
  simrun.sh                  launcher: clean → env layering → bridge → anchors →
                             one terminator window per vehicle
  agent_net.sh               netns anchor container (owns namespace + port map)
  term_tabs.sh               terminator window builder ("name::cmd" manifest)
  wait_for.sh                readiness probes: container | tcp | fg-telnet | fg-props
  clean.sh                   teardown by naming regex ^(agent|fgfs|px4-sitl)[-_]ID$
  profiles/                  terminator.run.<name> manifests + <name>.env defaults
  tools/validate.sh          staged layer validation
fgear/craft_base_24/
  run.sh                     renderer container (modes standalone|external-fdm)
  tools/fg_prop.py           props telnet get/set (THE machine-readable channel)
  tools/feed_fdm.py          reference fg_protocol pose sender
  tools/validate.sh          layer validation (29 stages + live)
px4/px4_gazebo_16/           FROZEN — used AS-IS, never edit; fixes go around it
  run.sh                     docker run --net=host --name px4-sitl-16 (no command
                             → container idles at bash; profile's 2_pxh execs
                             ./runGzPX4.sh: PX4_SIM_MODEL=gz_x500 + stock rcS)
debug/collect-logs.sh        the collector that produced your bundle
```

When repo code and docs disagree, **the code wins** — read the script, don't
trust prose. Layer readmes: `orch/v1/readme.md`, `fgear/craft_base_24/readme.md`.

---

## Bundle layout (`collect-logs.sh` output)

```
sims-logs-<ts>/
  MANIFEST.txt      index + per-container log line counts. READ FIRST —
                    "NONE MATCHED" means collection ran AFTER a relaunch's
                    auto-clean deleted the containers (their logs are gone).
  docker/           docker logs of each sim container, one file per name:
    fgfs_<ID>.log     renderer console (fgfs args, Xvfb, GL, scenery, protocol) ★
    px4-sitl-16.log   PX4/gz console (arming refusals, EKF, mode rejects) ★
    agent-<ID>.log    anchor (near-empty sleeper — presence matters, not content)
  inspect/          docker inspect JSON per container: env actually injected,
    <name>.json     mounts, network mode, State.ExitCode/OOMKilled ★ for crashes
  fg/               props-telnet snapshot per LIVE renderer (position, heading,
    fgfs_<ID>.props.txt   elapsed-sec) — absent file = renderer wasn't answering
  px4/              the px4-fg flight-log bind mount (<root>/logs): PX4 ulog etc.
  system/
    docker-ps.txt     Up vs Exited — check BEFORE blaming logic ★
    sim-net.json      bridge membership (fg-demo; absent/error on host-net runs)
    docker-images.txt built images (missing fgfs-base:24 / px4-sitl-16 = never installed)
    host.txt          uname + git rev + dirty files
    env/              env.list + profiles/*.env + local.env (the layered config)
```

★ = highest-signal artifacts for most investigations.

**Coverage caveats** (so you don't misread silence as "fine"):

- **Terminator tab output is NOT captured.** Tab-level failures (a `wait_for.sh`
  timeout, `mkdir` permission error, a typo'd command) appear only in the tab's
  scrollback, never in `docker logs` — the container just doesn't exist. A
  missing per-ID file in `docker/` usually means exactly that: check
  `system/docker-ps.txt` and ask the user what the tab showed.
- `fg/` files exist only for renderers alive AND answering at collect time.
- `px4/` is only populated by px4-fg runs where PX4 actually created logs.
- Per-container logs use each container's own clock — correlate by content and
  sequence, not raw timestamps.

---

## Verification channels (for checks & repro suggestions)

```bash
# renderer state, machine-readable (fg-demo host edge 1577<ID>; host-net 15777)
python3 fgear/craft_base_24/tools/fg_prop.py --port 15771 get /position/latitude-deg
# readiness probes (what the profiles themselves use for sequencing)
./orch/v1/wait_for.sh fg-props 15771       # protocol-level, docker-proxy safe
./orch/v1/wait_for.sh container px4-sitl-16 60
# LIVE px4-fg only: decode WHY arming is denied (health_report + per-mode
# requirement flags via px4-listener; read-only) — pxh's console never
# prints the detailed check failures, they go out via MAVLink events
./debug/px4-health.sh
# PX4 ulog in px4/ (if present):  pip install pyulog;  ulog_info <file>.ulg
# the plan without touching anything:
SIM_DRYRUN=1 ./orch/v1/simrun.sh 2 --config fg-demo
```

---

## Known failure modes & invariants (diagnostic checklist)

Map the symptom against these before theorizing something exotic:

**Orchestration / containers**

- **`ID` must be set and unique** — container suffix, window title, port-map
  token. Naming is strictly `^<base>[-_]<ID>$`; a renamed container breaks
  netns joins AND teardown AND this collector's matching.
- **The anchor `agent-$ID` owns the vehicle's netns** — if it died, every
  joined service lost networking; check `inspect/agent-<ID>.json` State first.
- **Names collide with another sim on the same host** (`fgfs_N`, `px4-sitl-N`,
  `agent-N`): a bundle may contain the OTHER project's containers, and
  clean.sh may have killed them. Check `inspect/` mounts to tell them apart.
- **simrun auto-cleans on every launch** — empty/missing docker logs after a
  relaunch are destroyed evidence, not a quiet run.
- docker-proxy ACCEPTS TCP on published ports before the backend listens —
  a "port open" observation proves nothing; only `fg-props`-style
  protocol-level probes count.
- dockerd cannot mkdir a missing bind-mount source on this station
  (permission denied at run) — mount sources must be pre-created as the user
  (that's why the px4 tab runs `mkdir -p logs &&` first).

**FlightGear renderer**

- `xvfb-run` hangs forever as container PID 1 — the runner starts its own
  Xvfb + `xdpyinfo` poll; containers must run `--init`.
- `fgfs` lives in `/usr/games`; version checks without X need
  `QT_QPA_PLATFORM=offscreen`.
- Ortho satellite ground needs **hardware GL** (`FGFS_GPU=intel`/host —
  llvmpipe renders teal synthetic terrain), runtime Nasal placement, and the
  −90° UV rotation baked into the `.ac` (fgear readme, render lessons).
- In external-fdm mode with no pose feed, FG sits frozen at home — with
  px4-fg's missing pose tap this is EXPECTED, not a failure.

**px4-fg specifics**

- The frozen image's CMD is `/bin/bash` — `1_px4` idling at a shell is normal;
  PX4+gz only run if `2_pxh`'s `docker exec ./runGzPX4.sh` fired. No PX4
  banner in `docker/px4-sitl-16.log`? The exec tab failed or was closed.
- QGC "Disconnected" = PX4 not (yet) running. When PX4 runs, stock rcS
  broadcasts heartbeats to UDP 14550 on the host net → QGC autoconnects with
  zero config. No rcS override is mounted in this profile.
- `px4-sitl-16`'s `16` is the PX4 version, not a vehicle ID (collector
  special-cases it; don't read it as "vehicle 16").
- Preflight "Accel/Gyro Sensor 0 missing" / "Found 0 compass" / "ekf2 missing
  data" while gz is demonstrably running (world clock ticking, topics listed)
  = the image's gz-sim 8.14 lazy-sensor regression: a sensor publishes only
  while a counted subscriber holds its topic, PX4's own gz_bridge subscription
  is not counted, and WHICH sensors gate is a per-run race. The `3_keepalive`
  tab (`orch/v1/sensor_keepalive.sh`) must be alive holding all four topics
  (imu/mag/baro/navsat). Confirm from uORB inside the container:
  `cd build/px4_sitl_default/rootfs && ../bin/px4-listener sensor_accel` —
  "never published" = the keepalive isn't covering that sensor.
  design/px4-fg-gz-sensor-keepalive.md.

**General**

- No health/restart automation — a crashed service stays dead; confirm
  liveness via `system/docker-ps.txt` before blaming logic.
- Sequencing is `wait_for.sh` probes in the profile lines; a tab that skipped
  its probe (edited profile, manual run) can race the netns owner.

---

## Investigation procedure (suggested)

1. **Orient.** `cat MANIFEST.txt`; `system/host.txt` (git rev + dirty files);
   `system/docker-ps.txt` (Up vs Exited); `system/env/` (which profile/knobs).
2. **Confirm scope.** Which containers/logs exist? Which are absent (never
   started vs cleaned)? Any renderer missing its `fg/` snapshot?
3. **Find the failing edge.** First error/traceback in the suspect container's
   `docker/*.log`; a non-zero `State.ExitCode`/`OOMKilled` in `inspect/`; a
   frozen `elapsed-sec` in `fg/`.
4. **Tie to source.** Map the error to the responsible script in the source
   map; read that code to confirm the mechanism (don't guess from the message).
5. **Cross-check the checklist** for a known failure mode that fits.
6. **Conclude.** Write up per the format below.

---

## Final report (deliver EXACTLY these three parts)

Keep every claim tied to evidence (cite the exact log line and the repo
`file:line`). Distinguish **Part 1** (fix THIS run's observed behavior) from
**Part 2** (broader hardening noticed along the way).

```
# Part 1 — What was wrong & how to fix it
## Summary
<1–3 sentences: what went wrong and the most likely root cause>

## Timeline (from the logs)
- <event/fact>  [evidence: docker/fgfs_1.log:L / inspect/…]
- … (anchor on the first failing edge)

## Root-cause hypotheses (ranked)
1. <hypothesis> — confidence: high/med/low
   Evidence: <exact log lines + repo file:line>
   Mechanism: <why this produces the symptom, referencing the code>

## Immediate fix
- <file:line> — <the change> — <why it corrects the OBSERVED_BEHAVIOR>
- Verify by: <a validate.sh assert, a props check, or a fresh-run metric>
- NOTE: px4/ is FROZEN — a fix needed there must instead go around it
  (profile line, wrapper, orchestrator), like the 2_pxh exec tab does.

## Gaps / what would pin it down   (only if the cause is uncertain)

# Part 2 — sims source-code suggestions
Improvements to the template itself surfaced by this investigation:
robustness, guards, readiness checks, config defaults, missing validation.
For each: <file:line> — <change> — <problem it prevents> — priority.
Structural changes need a user-approved plan first (working rule #1).
If nothing beyond Part 1 is warranted, say so explicitly.

# Part 3 — Log-collection improvements (next collect / re-collect)
- **Re-collect now (no code change):** can the bundle be improved by just
  re-running `debug/collect-logs.sh` (e.g. taken after clean wiped the
  containers, an --id filter dropped data)? Exact command, or "data is gone".
- **Collection-logic changes to implement:** concrete edits so the missing
  signal is recorded next time. Candidate sites:
    debug/collect-logs.sh      capture an extra source (more props, gz topics,
                               container resource stats, dmesg)
    orch/v1 profiles           tee tab output to a logs dir (the biggest known
                               gap: tab-level failures are uncaptured today)
    fgear run.sh / wait_for.sh emit/record a missing readiness or error signal
  Note whether each needs a fresh run to take effect.
```

If the bundle lacks containers ("NONE MATCHED") or a snapshot, say so up front
and work from what's present rather than inferring. Prefer the smallest fix
that addresses the *root* cause over patching the symptom.
