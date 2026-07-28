# sims — layer conventions & orchestration contract

Rules every layer in this repo follows so that layers compose into multi-agent
simulations and can be driven by a future orchestrator (simrun-style launcher +
terminal-tab manifests + profiles). Distilled from a production multi-drone sim,
where this model runs N-agent fleets in production. The `fgear/craft_base_24`
layer is fully compliant; `px4/*` predates the contract and is kept as-is
(notes below on how it plugs in).

## 1. The agent model

An **agent** (one simulated vehicle) is a *group of containers sharing one
Linux network namespace* — not one container.

* One container per agent is the **netns owner** (e.g. `px4-sitl-$ID`); it
  starts FIRST. Every other container of that agent joins it with
  `--network container:<owner>` (fgear: `FG_NET=container:<owner>`).
* **Internal ports are identical across agents on purpose.** Isolation comes
  from the namespace, never from per-ID port renumbering. Never "fix" a port
  collision by renumbering.
* Cross-agent traffic (inter-vehicle) goes over a dedicated docker bridge
  network the owners additionally connect to — not over per-agent ports.

## 2. ID threading

The ONE per-agent variable is the integer **`ID`**, threaded purely through the
environment: orchestrator → terminal tab → run script → `docker run --env ID`.

* Per-agent scripts hard-fail fast when `ID` is unset (`[ -z "${ID:-}" ] && exit 1`)
  — unless they meaningfully support a single-instance default (fgear does:
  unset `ID` = instance "fgfs", title "FlightGear").
* `ID` drives every per-agent name: container suffix, window title, named
  volumes, MAV_SYS_ID-style identities.

## 3. Naming

* Containers: `<base>_$ID` or `<base>-$ID` — strictly `^<base>[-_]<ID>$`, so a
  teardown script can match and remove by regex. Never rename ad-hoc; netns
  joins and teardown both key on the name.
* Named volumes: `<base>_<what>_$ID` (e.g. `fgfs_home_3`).
* Run scripts `docker rm -f <name>` before `docker run --rm` — a leftover name
  must never block a relaunch (tab restart = clean relaunch).

## 4. Config layering

Precedence everywhere: **explicit env > env file > built-in default.**

* `env.list` (tracked) — the shared simulation env, injected into every
  container via `--env-file`. One file per project, not per layer.
* `local.env` (untracked, gitignored) — per-STATION knobs only (GPU backend,
  window placement); auto-sourced by the orchestrator with `set -a`. Generated
  by an idempotent `deps.sh` on a fresh machine, never clobbering a tuned one.
* Layer defaults live in the run scripts themselves and must be safe with an
  empty environment.
* Values may carry stray trailing spaces (hand-edited env files) — strip them
  at the point of use (`${VAR// /}`).

## 5. Run-script contract (what a future orchestrator relies on)

Every layer's `run.sh`:

1. is location-independent (resolves its own dir; never depends on caller cwd),
2. reads ALL configuration from env (documented in an `env.list.example`),
3. runs `--rm` foreground so a terminal tab shows the live log and Ctrl-C kills
   the container,
4. supports `bash` as first arg for a debug shell in the image,
5. supports a dry-run env knob that prints the assembled command (CI/asserts),
6. exposes a network-mode knob (`bridge | host | container:<owner>`),
7. keeps mounts live-editable where possible (code/assets bind-mounts beat
   rebuilds during development).

## 6. Tab-manifest format (implemented: [`orch/v1`](./orch/v1/readme.md))

`orch/v1/simrun.sh` is the reference implementation of this section: it boots N
vehicles (netns anchor `agent-$ID` each), the shared bridge, and ONE Terminator
window PER VEHICLE titled `agent-<ID>`, holding that vehicle's tabs numbered
`<seq>_<name>` (each tab exporting its own `ID`); the profile's `@once:`
ground-station tabs join `agent-1`'s window.
Profiles are plain-text tab manifests, one service per line:

```
# terminator.run.<profile>   —   "tabname::command"
px4::./px4/px4_gazebo_16/run.sh
fgfs::sleep 2 && FG_MODE=external-fdm FG_NET=container:px4-sitl-16 ./fgear/craft_base_24/run.sh
```

* `--config <profile>` in the launcher just selects which manifest file loads —
  a profile is nothing more than a text file.
* Each line inherits the launcher's environment; `ID` is set per tab (the
  window is shared, so it cannot come from the process env).
* `sleep`-based sequencing is the current (known-weak) ordering mechanism; a
  readiness probe per layer is the desired upgrade — fgear already exposes one
  (props telnet answers ⇒ renderer up: `tools/fg_prop.py get /sim/time/elapsed-sec`).

An orchestrator then needs only: tear down the previous run → create shared
bridge network → per ID: create the netns owner and connect it to the bridge →
launch ONE tab window (per-ID manifest tabs with `ID` set per tab + the
ground-station tabs once). Teardown = remove containers matching the §3 regex
+ the bridge.

## 7. Validation

Every layer ships a `tools/validate.sh` (or equivalent) with staged depth:
static checks → pure-logic self-tests → dry-run arg assembly → image build →
image smoke → live end-to-end. The live stage must work HEADLESS (no display,
no GPU) so it can run in CI: fgear does xvfb + software GL + UDP pose feed +
props-telnet asserts.

Verification style: assert through machine-readable side channels (property
trees, telemetry logs), not screenshots.

## 8. How the current px4 layer plugs in (left as-is by decision)

`px4/px4_core_16` / `px4_gazebo_16` predate this contract: single hardcoded
container name (`px4-sitl-16`), `--net=host`, no `ID`. They work unchanged as a
single-agent netns owner under the manifest above (fgear joins with
`FG_NET=container:px4-sitl-16`). When multi-agent PX4 is needed, bring the
layer up to §§2–5 (ID-suffixed name, netns-owner mode, env-file, dry-run) — the
fgear `run.sh` is the reference implementation of the contract.

The renderer consumes vehicle pose; the adapter that turns the sim's pose into
`fg_protocol` datagrams (a "pose tap", the modern replacement for the
reference sim's patched-Gazebo UDP stream) belongs to the project/pipeline
layer —
`fgear/craft_base_24/tools/feed_fdm.py` is its reference sender, and
`orch/v1/pose_tap.sh` + `orch/v1/tools/pose_tap.py` (MAVLink → fg_protocol,
design/px4-fg-pose-tap.md) is the shipped px4-fg implementation.
