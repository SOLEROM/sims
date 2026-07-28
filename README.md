# sims

simulation playground — reusable simulation layers, built to compose into
multi-agent setups (template distilled from a production multi-drone sim).

* [`CONVENTIONS.md`](./CONVENTIONS.md) — the layer contract: agent = netns
  group, `ID` threading, naming, config layering, tab-manifest orchestration.
* `orch/` — orchestration layer. Current: **`v1`** (`simrun.sh N --config
  <profile>`: netns anchors `agent-$ID`, Terminator tab windows, profiles,
  `clean.sh`; see its readme).
* `fgear/` — FlightGear layer. Current: **`craft_base_24`** (standalone +
  external-fdm drone-camera renderer; see its readme).
* `px4/` — PX4 SITL layer: `px4_core_16` (v1.16), `px4_gazebo_16` (v1.16 + gz
  Harmonic).
* `debug/` — run forensics: `collect-logs.sh` snapshots a run's logs + state
  into a shareable `/tmp` bundle; `debugPrompt.md` is the paste-to-Claude
  investigation prompt for it (see its readme).
* `design/` — feature & architecture notes: one md per decision (observed →
  root cause → decision → rejected alternatives).
* `offboards/` — offboard-control playground.
* `ref/` — reference notes/links.
