# px4-fg pose tap — PX4 physics → FlightGear camera (and why it needs a dedicated MAVLink instance)

Status: implemented + live-validated (2026-07-23). Code:
`orch/v1/pose_tap.sh` (wrapper tab) + `orch/v1/tools/pose_tap.py` (bridge).

## Observed

px4-fg had every link except the one that makes the renderer worth having:
QGC ↔ PX4 worked, PX4 ↔ gz physics worked, FlightGear started in
external-fdm mode listening on UDP 15778 — and then sat at its init pose
(KSFO, 5 ft) forever, because nothing converted the sim's pose into
`fg_protocol` datagrams. Flying in QGC changed nothing on the FG screen.

## Decision

`5_pose` tab = `orch/v1/pose_tap.sh`:

1. Creates a **dedicated PX4 mavlink instance** at runtime (`docker exec
   px4-mavlink start -x -u 14590 -r 4000000 -m onboard -o 14591`) — the
   frozen px4 layer is untouched, same injection pattern as `PX4_HEADLESS`.
2. Runs `tools/pose_tap.py`: binds UDP 14591, hellos `14590` (1 Hz
   heartbeat + `SET_MESSAGE_INTERVAL` for `GLOBAL_POSITION_INT` + `ATTITUDE`
   at 30 Hz every 5 s), converts each fix into the 9-field `fg_protocol`
   datagram (deg / **feet AMSL** / nadir cam pitch −85) → UDP 15778.
3. The tap exits rc 2 after 20 s of MAVLink silence; the wrapper loops and
   re-creates the instance — so Ctrl-C in the pxh tab + a fresh
   `./runGzPX4.sh` self-heals.

stdlib only: the three MAVLink messages involved are hand-coded against the
frozen v1/v2 wire format (`MSGS` table + MCRF4XX CRC with the spec's
crc_extra seeds; a wrong seed = 100 % CRC rejects = loud stall, never silent
garbage). `pose_tap.py --selftest` covers CRC/framing/zero-trim/conversion
plus a fake-PX4→tap→fake-FG loopback (14 checks).

## Root cause of the hard part: the stock 14540 link can be stolen

First attempt was the obvious one — passively bind 14540, the documented
SITL offboard port (`px4-rc.mavlink` starts the onboard instance with
`-o $((14540+px4_instance))`). It received **nothing**, on a live sim whose
instance-1 `telemetry_status` showed 165 k messages sent at 22 kB/s.

An in-container `AF_PACKET` sniff of `lo` gave the answer: the stream was
going to `127.0.0.1:54278` — a long-dead ephemeral port. **PX4 v1.16's UDP
mavlink latches its partner address to the FIRST packet source it ever
hears, even when `-o` preconfigured one, and never re-learns** (1 Hz hello
heartbeats from the correct socket did not win it back). Any stray packet to
14580 — a GCS port scan, a health probe, an old tool's socket — permanently
hijacks the link until PX4 restarts. The same latch is why QGC owns the GCS
link (18570→14550) exclusively once connected.

Ports that only the tap touches have no contention, hence the dedicated
instance on 14590→14591 (clear of the stock 14540/14550/14280/13030 families
and of multi-instance offsets).

## Validated (live, against a running px4-fg sim)

* Tab dry-run renders `5_pose::export ID=1; ./orch/v1/pose_tap.sh`
  (validate.sh asserts it; qgc/debug renumber to `6_qgc`/`7_debug`).
* On tap start, FG jumped 9000 km from its init pose to the vehicle:
  `/position/latitude-deg 47.397971` vs PX4 `vehicle_global_position lat
  47.397968` (≤3e-6°), heading = EKF yaw, cam pitch −85, values updating
  live at stream rate.
* Flight-follow (QGC takeoff → FG climbs) couldn't be exercised in that run:
  arming was blocked by a pre-existing `local_position_estimate` failure
  (the per-run gz sensor gating — see
  [`px4-fg-gz-sensor-keepalive.md`](./px4-fg-gz-sensor-keepalive.md)), which
  is upstream of and unrelated to the tap.

## Rejected

* **pymavlink / MAVSDK** — not installed on the station; layer tools are
  stdlib-only by convention and the template stays dependency-free for three
  fixed messages.
* **gz-transport tap** (`docker exec gz topic -e .../pose/info` piped out) —
  physics ground truth, but couples the bridge to gz CLI output format and a
  long-lived exec pipe through the frozen container; in SITL the EKF
  estimate is what QGC shows and is the right "what the drone believes"
  feed for a camera.
* **Passive bind on stock 14540** — the partner-latch failure above.
* **Sharing the GCS link (18570)** — QGC's latch owns it; two consumers
  can't coexist on one PX4 UDP link.

## Caveats

* A future offboard companion (MAVSDK agent etc.) must get its OWN instance
  too — never point it at 14590/14591, and don't let anything else poke
  those ports.
* `mavlink status` output goes to the SERVER console (the pxh tab), not the
  `px4-mavlink` client — diagnose links with
  `px4-listener telemetry_status` instead.
