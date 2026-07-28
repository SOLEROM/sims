# CLAUDE.md — sims template repo

Fast context for a fresh shell. Read this, then `CONVENTIONS.md`, then the
readme of whatever layer you touch.

## What this repo is / what we're doing

Reusable **simulation-layer template** distilled from a production multi-drone
sim (an in-house reference project, spun via `./sim/simrun.sh N --config sim`).
Ongoing effort (2026-07): generalize that stack into composable, per-layer
building blocks here so future projects start from this template instead of
copying it. The reference project stays untouched.

## Working rules (user-mandated, non-negotiable)

1. **No additions or refactors without a plan presented and approved first.**
   Small explicitly-requested items (a doc, a script the user asked for) are
   fine; anything structural needs approval.
2. **`px4/` layer is FROZEN** — use as-is (v1.16 + gz Harmonic), never update.
   How it plugs in despite predating the conventions: `CONVENTIONS.md` §8.
3. **Don't launch sims/builds for the user unasked** — present the command,
   let them run it (or get an explicit go-ahead).

## Architecture in one breath

An **agent** (simulated vehicle) = a group of docker containers sharing one
Linux netns; a tiny anchor container `agent-$ID` owns the namespace + host
port map, others join via `--network container:agent-$ID`. The single
per-agent variable is env var **`ID`**; internal ports are identical across
agents (isolation by netns, NEVER per-ID renumbering). Config layering:
explicit env > env file > built-in default. Full contract: `CONVENTIONS.md`.

## Layout & status (all new work validated, currently UNCOMMITTED)

* `CONVENTIONS.md` — the layer contract (agent model, ID threading, naming
  regex, run-script contract, tab manifests, validation style).
* `fgear/craft_base_24/` — FlightGear 2020.3 (ubuntu 24.04) drone-camera
  renderer, modes `standalone` | `external-fdm` (pose in via `fg_protocol`
  UDP 15778, props telnet 15777). Ships tools/ (exact-simgear tile math,
  ortho/objects generators, pose feeder, validate). **29/29 + live headless
  PASS.** `craft_base_20` is frozen history.
* `orch/v1/` — orchestrator: `simrun.sh N --config <profile>` (default profile
  `px4-fg`; `--help` works)
  → auto `clean.sh` first (fresh run; `--no-clean` skips), netns anchors, then
  one Terminator window PER VEHICLE titled `agent-<ID>` with numbered
  `<seq>_<name>` tabs; `@once:` tabs join `agent-1` (e.g. N=2 fg-demo:
  agent-1 = `1_fgfs 2_feed 3_info`, agent-2 = `1_fgfs 2_feed`).
  Profiles: `fg-demo` (N self-contained renderers + circling pose feeders),
  `px4-fg` (frozen px4 as netns owner on host net, single vehicle, FG joins
  it; `2_pxh` tab auto-starts PX4+gz via `docker exec ./runGzPX4.sh` since the
  frozen image's CMD is just bash; gz physics HEADLESS by default,
  `PX4_HEADLESS=0` pops the Gazebo GUI window; `3_keepalive` tab holds gz
  subscriptions on ALL four sensor topics (imu/mag/baro/navsat) — the image's
  gz-sim 8.14 publishes a sensor only while subscribed, and which sensors gate
  varies per run: without it accel/gyro/compass go missing and nothing can arm
  (design/px4-fg-gz-sensor-keepalive.md); `5_pose` tab = the pose tap:
  a DEDICATED mavlink instance (UDP 14590→14591, created via docker exec —
  the stock 14540 link latches onto the first stray packet source,
  design/px4-fg-pose-tap.md) bridged to fg_protocol UDP 15778 so the FG
  camera follows QGC flying; `7_debug` tab = shell in
  `debug/` for px4-health.sh; QGC autoconnects via MAVLink
  broadcast to UDP 14550).
  **35/35 + live PASS.**
* `px4/` — FROZEN. `px4_gazebo_16` owns the image tag `px4-sitl-16` (the
  core variant documents the same tag — gazebo is the right one; last build
  wins).
* `debug/` — run forensics (the reference `sim/master/collect-logs.sh`
  generalized): `collect-logs.sh` snapshots docker logs + inspect + FG props + px4 flight
  logs + system/env state of a run into `/tmp/sims-logs-<ts>/` (+ .tgz);
  read-only, and must run BEFORE a relaunch (simrun's auto-clean deletes the
  container logs). `debugPrompt.md` = paste-into-a-fresh-Claude forensics
  prompt for a bundle. **13/13 PASS.**
* `design/` — feature & architecture decision notes (observed → root cause →
  decision → rejected). Write one when a non-obvious behavior gets decided.
* `install.sh` — idempotent station setup (host tools, local.env, image
  builds + smoke). `./install.sh --check` = report only. PX4 image build is
  the heavy step (tens of minutes).

## Quick commands

```bash
./install.sh --check                      # station readiness, changes nothing
./orch/v1/simrun.sh 2 --config fg-demo    # 2-vehicle renderer demo
SIM_DRYRUN=1 ./orch/v1/simrun.sh 2 --config fg-demo   # print the plan
./orch/v1/clean.sh [-n] [ID]              # teardown (dry-run / scoped)
./debug/collect-logs.sh                   # snapshot run logs BEFORE relaunching
./fgear/craft_base_24/tools/validate.sh --live   # layer's own staged tests
./orch/v1/tools/validate.sh --live
```

Per-station knobs live in `orch/v1/local.env` (untracked; `FGFS_GPU`,
`QGC_CMD`, `PX4_HEADLESS=0` for the gz GUI window, window placement).

## Hard-won gotchas (don't re-learn these)

* `xvfb-run` hangs forever as container PID 1 (Xvfb's SIGUSR1-ready never
  reaches pid 1) → runner starts its own Xvfb + `xdpyinfo` poll; always
  `docker run --init`.
* docker-proxy ACCEPTS TCP on published ports before the backend listens →
  never trust a plain TCP connect; use `wait_for.sh fg-props` (protocol-level
  probe).
* `fgfs` lives in `/usr/games` (not on default PATH); `fgfs --version` needs
  `QT_QPA_PLATFORM=offscreen` without X.
* Ortho rendering needs hardware GL (`FGFS_GPU=intel`/host — llvmpipe fails),
  ground placed at runtime via Nasal (`/ortho` props), and the −90° UV
  rotation baked into the .ac (see `fgear/craft_base_24/readme.md`).
* The reference sim's old tile script had a wrong SGBucket span (0.125 at
  |lat|≥22); `tools/fg_tiles.py` is the exact-simgear fix — trust it, it has selftests.
* Container names (`fgfs_N`, `px4-sitl-N`, `agent-N`) collide with the
  reference sim running on the same host — don't run both, or override
  `CLEAN_PATTERNS`.

## Validation style

Every layer ships `tools/validate.sh`, staged: static → selftests → dry-run
asserts → image build → smoke → live headless end-to-end. Assert through
machine-readable channels (props telnet, logs), never screenshots.
