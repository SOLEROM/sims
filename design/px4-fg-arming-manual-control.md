# px4-fg: "Arming denied: Resolve system health failures first" (no manual control)

*2026-07-23 — status: diagnosed + live probe shipped (`debug/px4-health.sh`);
QGC-ini automation proposed, awaiting approval.*

## Observed

`commander arm` in the pxh tab was denied on every attempt:

```
pxh> INFO  [tone_alarm] notify negative
WARN  [commander] Arming denied: Resolve system health failures first
```

— while everything actually looked healthy. Investigated live (bundle
`/tmp/sims-logs-20260723-161157` + read-only uORB probes into the running
`px4-sitl-16`).

## Root cause

**Nothing is unhealthy — the vehicle sits in MANUAL mode with no stick
input, and the denial message is a misleading generic.**

* PX4 boots into `nav_state=0` (MANUAL) when no RC is present. MANUAL (and
  ALTCTL/POSCTL/ACRO/STAB) require manual control input to arm.
* No source exists: no RC, and QGC's Virtual Joystick is **off by default**
  — `manual_control_setpoint` had literally never been published
  (timestamp 0). QGC itself was connected fine (`gcs_connection_lost: False`).
* The message text is a catch-all: `Commander.cpp:601` prints
  *"Resolve system health failures first"* whenever
  `canArm(current nav_state)` fails, whatever the reason.
* It *looks* like a health failure because `modeCheck.cpp` reports every
  unmet per-mode requirement as an `armingCheckFailure` against component
  `system` (`health_component_t::system`) — live `health_report` showed
  `arming_check_error_flags = 1<<20` (system) + warning `1<<7`
  (manual_control_input), while `health_error_flags = 0` and the EKF was
  fully converged (GNSS fused, home set, local+global position valid).
* The detailed per-check reasons only go out via the MAVLink **events**
  protocol (QGC displays them); the pxh console never prints them — hence
  the dead-end console message. `debug/px4-health.sh` fills that gap.

**Why offboard-flown stacks never hit this:** they never arm MANUAL from a
console. Each vehicle runs an offboard companion that flies programmatically
over MAVLink: it streams OFFBOARD position setpoints and arms via
`MAV_CMD_COMPONENT_ARM_DISARM`. OFFBOARD/AUTO modes don't require manual
control, so arming "just works" on every boot. px4-fg has no offboard
companion yet, so a pxh `commander arm` exercises a path such stacks never
use.

## Decision

* **`debug/px4-health.sh` (implemented)** — read-only live decoder: queries
  the running container via the px4 client (`px4-listener`
  `vehicle_status`/`failsafe_flags`/`health_report`), decodes the bitmasks
  and per-mode requirement flags, and prints the actual blocker for the
  current mode + which modes could arm. Referenced from `debug/readme.md`
  and `debugPrompt.md`.
* **Arming px4-fg today (no repo change), pick per need:**
  * `pxh> commander takeoff` — AUTO_TAKEOFF is armable without sticks;
  * upload a mission in QGC and press Start (AUTO_MISSION);
  * for hand-flying: enable **QGC → Application Settings → Fly View →
    Virtual Joystick** once. QGC persists it in
    `~/.config/QGroundControl.org/QGroundControl.ini`, per station, so a
    single UI toggle IS "default on" for all future boots — the sim never
    touches that file.
* **Long term:** a small offboard feeder companion alongside the pose tap
  (future work, needs a plan).
* **Proposed, not yet approved:** automate the ini for fresh stations — a
  pre-launch guard in the `@once:qgc` tab (or `install.sh` step) that sets
  `virtualJoystick=true` under `[App]` only when QGC is not running.

## Rejected alternatives

* **Patch the QGC ini immediately** — QGC was running, and it rewrites its
  ini on exit; the edit would be silently lost. Any automation must gate on
  "QGC not running" (hence the proposal above).
* **`param set COM_RC_IN_MODE 4` (sticks disabled) or force-arm
  (`ARM_DISARM` magic 21196)** — masks the check instead of providing
  input; force-arm skips *all* safety checks; both diverge from how the
  reference actually flies.
* **Bake params / rcS changes into the px4 image** — the `px4/` layer is
  FROZEN (working rule #2); fixes go around it.
