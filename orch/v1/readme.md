# orch/v1 — vehicle orchestration layer (simrun + terminator + profiles)

One command boots **N vehicles**, one Terminator window per vehicle,
titled `agent-<ID>`: inside it the profile's docker service tabs
(numbered `<seq>_<name>`, all sharing that vehicle's network namespace); the
profile's run-once `@once:` tabs (ground station etc.) join `agent-1`'s
window. All on top of a shared inter-vehicle bridge. Every launch first tears
down the previous run (`clean.sh`; skip with `--no-clean`). Generalized from a production
multi-drone launcher; implements [`CONVENTIONS.md`](../../CONVENTIONS.md).

```bash
./orch/v1/simrun.sh 2 --config fg-demo    # 2 vehicles of the self-contained demo
./orch/v1/clean.sh                        # tear everything down (-n dry-run, [ID])
SIM_DRYRUN=1 ./orch/v1/simrun.sh 3        # print the plan, touch nothing
./orch/v1/tools/validate.sh --live        # staged validation incl. real boot
```

## Pieces

| file | role |
|------|------|
| `simrun.sh` | N + `--config <profile>` (default `px4-fg`; `--help` for all flags): pre-run `clean.sh`, env layering, bridge net (`sim-net`), per-ID anchor, then one window `agent-<ID>` per vehicle with its `<seq>_<name>` tabs (+ `@once:` tabs in `agent-1`) |
| `agent_net.sh` | per-vehicle netns **anchor** container `agent-$ID`: a tiny sleeper that OWNS the namespace + the host port map, so services crash/restart without killing the vehicle's networking |
| `term_tabs.sh` | Terminator window builder (`name::cmd` tabs; proven launcher) |
| `wait_for.sh` | readiness probes replacing `sleep` chains: `container`, `tcp`, `fg-telnet`, `fg-props` (protocol-level — use through docker **published** ports, where a plain TCP connect false-positives against docker-proxy) |
| `clean.sh` | teardown by the conventions naming regex + the bridge; `-n` dry-run, `[ID]` scoped |
| `profiles/` | `terminator.run.<name>` manifests + optional `<name>.env` profile defaults |
| `env.list` / `local.env` | tracked sim-wide env / untracked station env (see `local.env.example`) |

## The vehicle model

```
                 host
  ┌─ vehicle 1 (netns of agent-1) ─┐   ┌─ vehicle 2 (agent-2) ─┐
  │ fgfs_1  feeder/…  <future svc> │   │ fgfs_2  …             │
  └───────────┬──────────────────┬─┘   └──┬────────────────────┘
        published ports        sim-net bridge (inter-veh)
        1577<ID>→15777 …         172.31.0.0/16
```

* Internal ports are IDENTICAL on every vehicle; only the anchor's host-side
  publish map (`AGENT_PUBLISH`, `%ID%` token) is per-ID.
* `ID` is the only per-vehicle variable, threaded purely through env:
  simrun → window → tab command → `docker run`.

## Profile manifests

```
# terminator.run.<name>
fgfs::FG_MODE=external-fdm FG_NET=container:agent-$ID ./fgear/craft_base_24/run.sh
feed::./orch/v1/wait_for.sh fg-props 1577$ID && python3 .../feed_fdm.py --port 1578$ID ...
@once:qgc::${QGC_CMD:-echo no ground station}
```

* plain lines → one tab in EACH vehicle's `agent-<ID>` window, named
  `<seq>_<name>` in window order (`1_fgfs`, `2_feed`); each tab
  `export ID=<n>` before the command, so `$ID` expands per-vehicle
* `@once:` lines → extra tabs at the end of `agent-1`'s window (no `ID`),
  continuing its numbering (`3_qgc`) — no extra window
* `#`/blank skipped; sequencing belongs in `wait_for.sh` calls, not `sleep`
* `profiles/<name>.env` (optional) carries profile defaults such as
  `AGENT_PUBLISH` or `SIM_NO_ANCHOR=1` (host-net profiles like px4-fg)

Env layering (later overrides earlier): `env.list` < `profiles/<name>.env` <
`local.env` (untracked, station-only).

## Shipped profiles

* **fg-demo** — self-contained: per vehicle a FlightGear drone-camera renderer
  (external-fdm, in the vehicle netns) + a circling `feed_fdm.py` pose feeder.
  Only needs the `fgfs-base:24` image. Verify any vehicle from the host:
  `python3 fgear/craft_base_24/tools/fg_prop.py --port 1577<ID> get /position/latitude-deg`
* **px4-fg** (default) — PX4 v1.16 + gz Harmonic (px4 layer used AS-IS →
  single vehicle, host network). `1_px4` = the container's shell (the frozen
  image's CMD is bash), `2_pxh` auto-starts PX4 + gz physics via `docker exec
  ./runGzPX4.sh` (pxh console) — gz headless by default, `PX4_HEADLESS=0` for
  the Gazebo GUI window (design/px4-fg-gazebo-headless.md) — plus `3_keepalive`
  (holds gz subscriptions on ALL four sensor topics — imu, mag, baro, navsat;
  the image's gz-sim 8.14 publishes a sensor only while subscribed, PX4's own
  bridge subscriptions aren't counted, and WHICH sensors gate varies per run —
  design/px4-fg-gz-sensor-keepalive.md), `4_fgfs` renderer, `5_pose` — the
  "pose tap" (CONVENTIONS §8): `pose_tap.sh` creates a DEDICATED mavlink
  instance in the container (UDP 14590→14591, runtime `docker exec`; the
  stock 14540 link latches onto the first stray packet source — see
  design/px4-fg-pose-tap.md) and `tools/pose_tap.py` converts its
  GLOBAL_POSITION_INT+ATTITUDE stream into `fg_protocol` datagrams on UDP
  15778, so the FG camera follows whatever QGC flies (extra flags via
  `POSE_TAP_ARGS`) — then the `@once:` QGC slot (`6_qgc`) and a `7_debug`
  shell opened in `debug/` (ready for `./px4-health.sh` etc.). QGC
  autoconnects: stock rcS broadcasts MAVLink heartbeats to UDP 14550, which
  any GCS on the host listens on by default. Needs the `px4-sitl-16` image
  (`./install.sh`).

## Validation

`tools/validate.sh` stages: static → simrun dry-run plan asserts → real anchor
lifecycle (create/publish/join/remove) → wait_for probes → clean dry-run →
`--live`: boots 2 fg-demo vehicles for real (terminator windows; renderers
headless inside their containers so the stage is GL-independent), asserts each
vehicle's pose is circling near home through the published telnet ports, then
`clean.sh` and asserts nothing is left.
