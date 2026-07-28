# design — feature & architecture notes

One md file per feature decision or architecture note: what we observed, why
the system behaves that way (root cause, with file:line evidence), what we
decided, and what was rejected. Written when the decision is made, so a fresh
session (or a future project forked from this template) doesn't re-derive it.

Not a duplicate of the layer readmes — those say *how to use* a layer; a
design note says *why it is the way it is*.

## Start here

* [`system-report.md`](./system-report.md) — **the full ground-truth system
  report**: what the stack is, the end-to-end data flow, the architecture
  model, every layer and shell script's responsibility, per-tab breakdown of
  the profiles, the complete port map, how to run/manage/debug, and the
  numbered architecture-decision record that indexes every note below.

## Notes

* [`px4-fg-gazebo-headless.md`](./px4-fg-gazebo-headless.md) — why px4-fg
  popped a separate Gazebo GUI window, and the `PX4_HEADLESS`
  knob that defaults it away without touching the frozen px4 layer.
* [`px4-fg-arming-manual-control.md`](./px4-fg-arming-manual-control.md) —
  why `commander arm` in pxh gets "Resolve system health failures first"
  when nothing is unhealthy (MANUAL mode + no RC/joystick — offboard-flown
  stacks never hit this), the `debug/px4-health.sh` probe, and the QGC
  Virtual Joystick per-station setting.
* [`px4-fg-gz-sensor-keepalive.md`](./px4-fg-gz-sensor-keepalive.md) — why
  boots randomly lost sensors (gz publishes a sensor only while it sees a
  counted subscriber, and PX4's own bridge isn't counted), the severance
  traps around subscriber lifecycle, and the epoch-aware `3_keepalive` tab
  that holds all four sensor topics.
* [`px4-fg-pose-tap.md`](./px4-fg-pose-tap.md) — the `5_pose` tab that closes
  the physics→renderer link (MAVLink → `fg_protocol`, FG camera follows QGC
  flying), and why it needs a DEDICATED mavlink instance: PX4 v1.16's UDP
  links latch their partner to the first packet source ever heard — the
  stock 14540 stream was found unicasting to a dead port.
* [`fg-ortho-arcgis-reaspect.md`](./fg-ortho-arcgis-reaspect.md) — the ~50 m
  imagery shift caused by the ArcGIS export endpoint silently re-aspecting
  mismatched extents, and the aspect-matched fetch + extent-honesty probe in
  the orthophoto generator.
