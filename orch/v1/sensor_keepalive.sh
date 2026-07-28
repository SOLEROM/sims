#!/bin/bash
# sensor_keepalive.sh — hold gz-transport subscriptions on the vehicle's
# sensor topics (px4-fg profile).
#
# WHY: the gz-sim shipped in the frozen px4-sitl-16 image (Harmonic 8.14)
# only computes/publishes a sensor while its publisher sees subscribers, and
# PX4 v1.16's own gz_bridge subscriptions are NOT counted (upstream
# regression) — a held CLI subscription is. WHICH sensors lose that race
# varies run to run (mag alone first, later the IMU too), so hold EVERY
# sensor topic PX4's bridge needs, not just the mag.
# Full story: design/px4-fg-gz-sensor-keepalive.md.
#
# HOW (v2 — epoch-aware, per-topic, make-before-break; the v1 drop-all shape
# lost a live vehicle at arming, see the design note's second follow-up):
#   * One held `gz topic -e` per topic, monitored and re-attached PER TOPIC.
#     Never drop-all/re-attach-all: on this gz build a zero-held-subscriber
#     window can PERMANENTLY sever PX4's own gz_bridge feed for a sensor —
#     gz resumes publishing to new CLI subscribers, but PX4 never hears that
#     sensor again until PX4 itself restarts.
#   * The in-container subscriber processes DO NOT exit when the gz server
#     dies (pxh Ctrl-C + a new ./runGzPX4.sh): they linger as previous-epoch
#     zombies that the NEW server may still count via discovery — the sensors
#     then ride processes nothing manages, until one dies mid-flight and
#     takes its sensor with it. So the loop tracks the gz SERVER pid as the
#     run epoch and reaps the zombies.
#   * KILLING a subscriber process while a sim runs is itself a severance
#     trigger, even with other subscribers held throughout (proven live:
#     reaping boot N-1's zombies during boot N's early life severed
#     baro+gps). So the reap happens in the pxh-restart DOWN WINDOW — server
#     gone, nothing to sever, wipe every subscriber for a clean slate — and
#     the new epoch then starts exactly like a proven-good fresh boot. The
#     after-attach reap remains only as a fallback for a missed down window
#     (restart faster than one poll).
#
# Env knobs (explicit env > profile env file > these defaults, conventions §3):
#   KEEP_CONTAINER  px4-sitl-16  container running the gz server
#   KEEP_GZ_WORLD   default      gz world name
#   KEEP_GZ_MODEL   x500_0       spawned model instance
#   KEEP_TOPICS     the four base_link sensors PX4's gz_bridge subscribes to
#                     (imu, magnetometer, air_pressure, navsat) —
#                     space-separated full override
#   KEEP_POLL       2            liveness/epoch poll period (s)
#   KEEP_WAIT       60           per-attempt container wait (s, wait_for.sh)
#   KEEP_TRIES      0            readiness attempts before giving up (0 =
#                                  retry forever; validate.sh uses 1 for a
#                                  fast timeout path)
set -uo pipefail

KEEP_CONTAINER="${KEEP_CONTAINER:-px4-sitl-16}"
KEEP_GZ_WORLD="${KEEP_GZ_WORLD:-default}"
KEEP_GZ_MODEL="${KEEP_GZ_MODEL:-x500_0}"
SENSOR_BASE="/world/${KEEP_GZ_WORLD}/model/${KEEP_GZ_MODEL}/link/base_link/sensor"
KEEP_TOPICS="${KEEP_TOPICS:-\
$SENSOR_BASE/imu_sensor/imu \
$SENSOR_BASE/magnetometer_sensor/magnetometer \
$SENSOR_BASE/air_pressure_sensor/air_pressure \
$SENSOR_BASE/navsat_sensor/navsat}"
KEEP_POLL="${KEEP_POLL:-2}"
KEEP_WAIT="${KEEP_WAIT:-60}"
KEEP_TRIES="${KEEP_TRIES:-0}"

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { echo "[sensor_keepalive] $*"; }

# shellcheck disable=SC2206  # KEEP_TOPICS is intentionally word-split
TOPICS=(${KEEP_TOPICS})
holds=()  # host-side `docker exec gz topic -e` client pid, one per topic
for _ in "${TOPICS[@]}"; do holds+=(""); done

drop_holds() {  # kill the local exec clients only — in-container subscriber
    local i     # procs linger on purpose (they keep the sensors computing)
    for i in "${!holds[@]}"; do
        [ -n "${holds[$i]}" ] && kill "${holds[$i]}" 2>/dev/null
        holds[$i]=""
    done
}
trap 'drop_holds; exit' INT TERM
trap 'drop_holds' EXIT

server_pid() {  # the gz SERVER (-s) inside the container; empty when down
    docker exec "$KEEP_CONTAINER" pgrep -of 'gz sim.* -s ' 2>/dev/null
}

reap_stale_subs() {  # $1 = server pid: kill in-container subscriber procs
    # STARTED BEFORE the server — previous-epoch zombies (start-time compare
    # via /proc/<pid>/stat field 22; comm has no spaces for either process)
    docker exec "$KEEP_CONTAINER" bash -c '
        sv=$(awk "{print \$22}" /proc/'"$1"'/stat 2>/dev/null) || exit 0
        [ -n "$sv" ] || exit 0
        for p in $(pgrep -f gz-transport-topic); do
            st=$(awk "{print \$22}" /proc/$p/stat 2>/dev/null) || continue
            [ -n "$st" ] && [ "$st" -lt "$sv" ] && kill "$p" 2>/dev/null
        done' 2>/dev/null
}

reap_all_subs() {  # sim DOWN window only: wipe every in-container subscriber
    docker exec "$KEEP_CONTAINER" pkill -f gz-transport-topic 2>/dev/null
}

epoch=""        # gz server pid the current holds belong to
reap_pending=0  # 1 = old-epoch leftovers still to reap once fully attached
tries=0
while :; do
    server=""
    if "$MYDIR/wait_for.sh" container "$KEEP_CONTAINER" "$KEEP_WAIT"; then
        server="$(server_pid)"
    fi
    if [ -z "$server" ]; then
        # pxh restart down window: the old sim is gone, nothing can be
        # severed — wipe the whole subscriber slate ONCE so the next boot
        # starts like a fresh one (no previous-epoch zombies at all)
        if [ -n "$epoch" ]; then
            say "gz server gone (pxh restart?) — wiping subscriber slate for the next boot"
            drop_holds
            reap_all_subs
            epoch=""
        fi
        if [ "$KEEP_TRIES" != 0 ]; then
            tries=$((tries + 1))
            if [ "$tries" -gt "$KEEP_TRIES" ]; then
                say "giving up after $KEEP_TRIES attempt(s)"
                exit 1
            fi
        fi
        sleep "$KEEP_POLL"
        continue
    fi
    tries=0

    if [ "$server" != "$epoch" ]; then
        [ -n "$epoch" ] \
            && say "gz server restarted (pid $epoch -> $server) — fresh subscriptions for the new epoch"
        drop_holds
        epoch="$server"
        reap_pending=1
    fi

    # (re)attach every topic whose client is gone — PER TOPIC, the others
    # keep their live subscription (no all-sensor gap)
    listed=""
    for i in "${!TOPICS[@]}"; do
        [ -n "${holds[$i]}" ] && kill -0 "${holds[$i]}" 2>/dev/null && continue
        [ -n "${holds[$i]}" ] && say "subscription dropped: ${TOPICS[$i]} — re-attaching"
        holds[$i]=""
        [ -n "$listed" ] || listed="$(docker exec "$KEEP_CONTAINER" gz topic -l 2>/dev/null)"
        if ! grep -qxF "${TOPICS[$i]}" <<<"$listed"; then
            say "waiting for topic ${TOPICS[$i]} (gz still booting?)"
            continue
        fi
        docker exec "$KEEP_CONTAINER" gz topic -e -t "${TOPICS[$i]}" >/dev/null 2>&1 &
        holds[$i]=$!
        say "attached: ${TOPICS[$i]}"
    done

    # reap previous-epoch zombies only AFTER the new epoch is fully held, so
    # any zombie the new server counts is replaced before it is removed
    if [ "$reap_pending" = 1 ]; then
        all=1
        for i in "${!TOPICS[@]}"; do [ -z "${holds[$i]}" ] && all=0; done
        if [ "$all" = 1 ]; then
            reap_stale_subs "$server"
            reap_pending=0
            say "all topics held (sensors publish only while held — keep this tab)"
        fi
    fi

    sleep "$KEEP_POLL"
done
