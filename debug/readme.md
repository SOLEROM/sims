# debug — run forensics layer (collect + investigate)

Snapshot everything a running (or just-finished) sim left behind into one
shareable folder, then hand it to a fresh Claude session with a ready-made
forensics prompt. Generalized from the reference sim's
`sim/master/collect-logs.sh` + `debugPrompt.md`.

```bash
./debug/collect-logs.sh                 # everything -> /tmp/sims-logs-<ts>/ (+ .tgz)
./debug/collect-logs.sh --id 2          # only vehicle 2   (--out DIR, --no-tar, -h)
./debug/px4-health.sh                   # LIVE: why is arming denied right now?
./debug/tools/validate.sh               # staged self-test (uses a scratch container)
```

`px4-health.sh` decodes the state behind pxh's generic *"Arming denied:
Resolve system health failures first"*: it queries the running `px4-sitl-16`
over the px4 client (uORB listeners, read-only), decodes the
`health_report` bitmasks and the per-mode requirement flags, and prints which
requirement blocks arming in the CURRENT mode plus which modes could arm.
The detailed check failures only go out via MAVLink *events* (QGC shows
them); the pxh console never prints them — this script fills that gap.

**Collect BEFORE relaunching** — `simrun.sh` auto-runs `clean.sh`, which
removes the containers and with them their `docker logs`. The collector itself
is strictly read-only (cp / docker logs / docker inspect / props reads).

## What lands in the bundle

| dir | content |
|-----|---------|
| `docker/` | `docker logs` of every sim container (conventions names over `COLLECT_PATTERNS`, default = clean.sh's bases `agent fgfs px4-sitl`) |
| `inspect/` | `docker inspect` JSON per container — injected env, mounts, network mode, exit code |
| `fg/` | best-effort FlightGear props snapshot per live renderer (position/heading/elapsed via props telnet: `1577<ID>`, else host-net `15777`) |
| `px4/` | the px4-fg flight-log bind mount (`<root>/logs` → PX4 ulog etc.) |
| `system/` | `docker ps -a`, `sim-net` inspect, images, host + git info, the layered env files (`env.list`, `profiles/*.env`, `local.env`) |
| `MANIFEST.txt` | index + per-container log line counts — read first |

The frozen `px4-sitl-16` is special-cased under `--id` (its `16` is the PX4
version, not a vehicle ID).

## Investigating a bundle

Paste **`debug/debugPrompt.md`** into a fresh Claude Code session and fill in
its INPUTS (`LOG_FOLDER=` + what looked wrong). It carries the system model,
source map, bundle layout, and the known-failure-mode checklist, and demands a
three-part evidence-cited report (fix / code suggestions / collection gaps).

## Known limits

- **Terminator tab output is not captured** — a `wait_for.sh` timeout or a
  failed tab command lives only in the tab scrollback (the container never
  existed). Teeing tab output is the known next improvement (needs a plan).
- Container names collide with another sim on the same host — a bundle may pick
  up the other project's containers (tell them apart via `inspect/` mounts).
- `fg/` snapshots exist only for renderers alive and answering at collect time.
