# px4-fg: missing sensors (mag, then IMU) — gz sensors need held subscribers

*2026-07-23 — status: implemented (`orch/v1/sensor_keepalive.sh` + `3_keepalive`
tab, holds ALL four sensor topics), proven live on the running sim; dry-run +
timeout-path asserts in `orch/v1/tools/validate.sh`. Originally shipped as a
mag-only keepalive (`mag_keepalive.sh`); generalized the same day — see
"Follow-up" at the bottom.*

## Observed

Every `px4-fg` boot ended arming-dead:

```
pxh> WARN  [health_and_arming_checks] Preflight Fail: Found 0 compass (required: 1)
```

and `debug/px4-health.sh` showed the full chain: preflight FAILED,
`local_position_invalid`, `global_position_invalid`, AUTO_LOITER blocked on
"no valid local/global position", **no mode could arm**. (Not the MANUAL
stick-input denial — that one is design/px4-fg-arming-manual-control.md.)

Also in the pxh console: `ERROR [mavlink] open failed: No such file or
directory` — a red herring, see below.

## Root cause

**The gz magnetometer never publishes, and everything else is downstream of
that one fact:** no mag → EKF2 cannot align yaw → it never produces a
local/global position (GPS itself streamed fine) → position-based modes block
arming.

Why the mag is silent: the frozen image carries gz Harmonic **gz-sim 8.14.0 /
gz-transport 13.5.0**, where sensor systems have a lazy-update optimization —
a sensor is only computed/published while its publisher **sees subscribers**
(`HasConnections()`). PX4 v1.16's `gz_bridge` subscribes to exactly the right
topic and its callback demonstrably works, but this gz build does **not count
that subscription** — while a `gz topic -e` CLI subscription IS counted
(upstream regression in the point release; IMU/baro/navsat still stream, the
magnetometer system is the one that gates).

Proven live against the running `px4-sitl-16` (read-only probes):

* Model/world/SDF all correct (`always_on=1`, 100 Hz); mag topic listed.
* The instant a `gz topic -e` subscriber attached, the sensor emitted its
  **first-ever** message (gz `seq: 0` at sim-time ~197 s) and it landed in
  uORB `sensor_mag`; detach → silent again; 5 s attached → 500 msgs (100 Hz).
* Subscriber held ~45 s → `px4-health.sh` flipped to **Preflight OK**,
  position valid, AUTO_LOITER/TAKEOFF/RTL all armable. Single root cause
  confirmed.

**Why earlier builds of the same image never showed this:** the recipe is
frozen but its apt output isn't — an older build resolved the gz-harmonic
metapackage to a point release without the regression; rebuilding the same
Dockerfile today (`install.sh` station setup) pulls 8.14.0.

**The mavlink error is unrelated:** `open failed` comes from
`mavlink_ftp.cpp` — QGC requesting component-metadata files over MAVLink-FTP
that the SITL rootfs doesn't ship. Benign, ignore.

## Decision

Orchestrator-level **mag keepalive** — hold the subscription the gz bug wants,
from outside the frozen layer:

* `orch/v1/mag_keepalive.sh` — waits for the container + topic
  (`wait_for.sh`-style gating, no sleep-sequencing), then holds
  `docker exec … gz topic -e -t <mag topic> > /dev/null`; if the subscription
  drops (pxh Ctrl-C + relaunch), it re-attaches forever. Knobs
  `MAG_CONTAINER/MAG_GZ_WORLD/MAG_GZ_MODEL/MAG_TOPIC/MAG_WAIT/MAG_TRIES`
  follow the env-layering contract; `MAG_TRIES` bounds retries so validate can
  exercise the give-up path fast.
* Profile tab `3_magkeep` in `terminator.run.px4-fg`, right after `2_pxh`
  (it is part of PX4 bring-up: pxh starts PX4+gz, magkeep makes the sensors
  actually stream). `fgfs` shifts to 4, `@once:` qgc/debug to 5/6.
* This is the same shape as the planned gz→`fg_protocol` "pose tap"
  (CONVENTIONS §8): a persistent host-side gz subscriber per vehicle — the
  pose tap can later absorb the keepalive by simply also subscribing to the
  mag topic.

## Rejected alternatives

* **Upgrade/pin gz-harmonic inside the image** — `px4/` layer is FROZEN
  (working rule #2); also apt archives don't keep every point release, so a
  pin is not reproducible either.
* **`SYS_HAS_MAG=0` / `EKF2_MAG_TYPE=none` params** — silences the preflight
  count but leaves the copter with no yaw reference; EKF still can't produce
  a trustworthy position. Wrong layer, worse vehicle.
* **`docker exec -d` one-shot from the pxh tab line** — no retry after a sim
  restart, invisible when it dies; a numbered tab with a retry loop shows its
  state and survives pxh relaunches.
* **Wait for the upstream fix** — unknown timeline, and the frozen image
  wouldn't receive it anyway.

## Follow-up (2026-07-23, same day): the IMU gates too — hold ALL sensors

The very next fresh run (17:05, log bundle `sims-logs-20260723-170553`) booted
with the mag keepalive attached and the mag streaming — but died differently:

```
WARN  [health_and_arming_checks] Preflight Fail: Accel Sensor 0 missing
WARN  [health_and_arming_checks] Preflight Fail: ekf2 missing data
WARN  [health_and_arming_checks] Preflight Fail: Gyro Sensor 0 missing
```

Live probes on that run (read-only): gz world ticking (RTF ~1.0), model
spawned, all topics listed; uORB `sensor_mag` + `sensor_baro` + `sensor_gps`
publishing, but `sensor_accel`/`sensor_gyro` **never published**. Holding a
`gz topic -e` subscription on the IMU topic made both appear within seconds,
and detaching silenced them again — identical mechanism, different sensor.
(Careful when re-probing: `px4-listener <topic> -n 1` prints the LAST stored
message even if stale — check its "seconds ago" age before calling a sensor
alive.)

So the earlier observation "IMU/baro/navsat still stream, only the
magnetometer gates" was true of THAT run only: **which sensors count PX4's
gz_bridge subscription is a per-run race**, not a fixed per-sensor property.
Decision: `mag_keepalive.sh` → `sensor_keepalive.sh`, holding one CLI
subscription per sensor topic PX4's bridge needs (imu, magnetometer,
air_pressure, navsat; override via `KEEP_TOPICS`); knobs renamed `MAG_*` →
`KEEP_*`; tab `3_magkeep` → `3_keepalive`.

Note on lifecycle: the in-container `gz-transport-topic` subscriber outlives
its `docker exec` client (docker does not proxy signals to non-tty execs), so
a held subscription also survives a pxh Ctrl-C + `./runGzPX4.sh` relaunch via
gz discovery — the tab's re-attach loop matters mainly for container
restarts. **(Superseded — Follow-up 2 below: it only HALF-survives, which is
worse than dying.)**

## Follow-up 2 (2026-07-23 evening): pxh restarts — zombie subscribers and a permanent gz→PX4 severance; keepalive v2

Post-mortem of the "armed + Takeoff detected, parked at 0.3 ft in Hold, one
mid-run `Accel #0 fail: TIMEOUT!`" run, plus live reproduction (fresh sim,
scripted pxh restart, read/kill probes), added three facts v1 missed:

1. **`gz topic -e` subscriber processes do NOT exit when the gz server dies.**
   After a pxh Ctrl-C + `./runGzPX4.sh`, the four in-container subscribers
   linger as previous-epoch zombies that the NEW server may still count via
   discovery. The restart boot then looks healthy ("Ready for takeoff!")
   while its sensors ride processes nothing manages — and v1's `wait -n`
   self-heal never fires, because its docker-exec clients are still attached
   to the living zombies.
2. **A zero-held-subscriber window can PERMANENTLY sever PX4's own feed.**
   Proven live: kill the zombies → v1 re-attaches fresh subscribers → gz
   resumes publishing (CLI echo sees the IMU at rate) — but uORB
   `sensor_accel` stays frozen forever. PX4 gz_bridge's subscription is gone
   at the transport level; only a PX4 restart re-subscribes. Which sensors
   sever vs recover is per-run roulette (this probe: accel+gyro severed, mag
   recovered — same shape as "which sensor gates varies per run").
3. **v1's all-or-nothing re-attach amplified the blast radius:** any single
   client death killed ALL four holds before re-attaching — a multi-second
   all-sensor zero-window, i.e. exactly the severance trigger, at a random
   moment.

Observed timeline, reconstructed: restart boot rode zombies → a zombie died
near arming → v1 dropped all four holds → accel severed in the gap →
`Accel #0 fail: TIMEOUT!` → armed anyway (check raced) with a dying EKF →
"Takeoff detected" with no valid local position → Hold at ground, forever.

And a fourth fact, learned from testing the first fix (v2's after-attach
reap severed baro+gps on the very next drill, with fresh subscribers held
throughout):

4. **KILLING a subscriber process while a sim runs is itself a severance
   trigger**, even when other subscribers stay attached the whole time — the
   publisher rebuilds its connection set on any subscriber loss and PX4's
   (uncounted) subscription can fall out of it. Corollary: subscriber
   cleanup may only happen while NO sim is running.

**Decision (implemented — `sensor_keepalive.sh` v2.1):**

* **Per-topic holds**: each subscription is monitored and re-attached
  individually; the other topics never lose their live subscription.
* **Epoch-aware via the gz SERVER pid, cleanup only in the DOWN WINDOW**:
  when the server disappears (pxh Ctrl-C), the loop wipes the entire
  in-container subscriber slate once — nothing can be severed while the sim
  is down — so the next boot starts exactly like a proven-good fresh boot,
  with no previous-epoch zombie left to die mid-flight. An after-attach reap
  of pre-server processes remains only as a fallback for a restart faster
  than one poll (KEEP_POLL, 2 s).
* **Detection** (`debug/px4-health.sh`, "sensor feeds (uORB freshness)"
  section): two timestamp samples per sensor; FROZEN/NEVER = severed feed,
  with the fix printed inline.

**Restart roulette, accepted:** even from a wiped slate, a pxh restart
INSIDE a lived-in container is not fully reliable on this gz build — live
drills saw a restart boot come up with one sensor unserved (navsat) while
the other four streamed, and a subscription-change event momentarily woke
it. Fresh-container boots (`simrun.sh`) have been reliable every time. So:
after any pxh restart, run `debug/px4-health.sh`; if a feed shows
FROZEN/NEVER, Ctrl-C pxh and rerun `./runGzPX4.sh` (or relaunch the run).
The keepalive's job is narrower and now done: no mid-flight sensor death in
a healthy boot, and restarts hand over from a clean slate.

Residual risk, accepted: an unexpected death of a single holder still opens a
one-topic window of up to KEEP_POLL (2 s); post-fix the remaining killers are
container-level events that take the whole vehicle down anyway.
