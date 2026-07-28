#!/bin/bash
# pose_tap.sh — keep a DEDICATED PX4 mavlink instance + pose_tap.py running
# (px4-fg profile: PX4/gz physics -> FlightGear camera pose bridge).
#
# WHY a dedicated instance: PX4 v1.16's SITL UDP mavlink links latch their
# partner address to the FIRST packet source they ever hear — even when -o
# preconfigures one. Any stray probe of the stock onboard link (14580->14540:
# a GCS scan, a health script, an old socket) permanently steals the stream
# until PX4 restarts. A private instance whose ports only the tap touches has
# no contention. Full story: design/px4-fg-pose-tap.md.
#
# Runs forever (profile tab): wait container -> ensure the instance (runtime
# `docker exec mavlink start`, frozen px4 layer untouched) -> run the tap.
# The tap exits rc 2 after POSE_IDLE_EXIT s of silence (e.g. Ctrl-C in the
# pxh tab + a new ./runGzPX4.sh lost the instance) -> loop re-ensures it.
#
# Env knobs (explicit env > profile env file > these defaults, conventions §3):
#   POSE_CONTAINER   px4-sitl-16  container running PX4
#   POSE_MAV_LOCAL   14590        dedicated instance's UDP port (PX4 side)
#   POSE_MAV_PORT    14591        tap's UDP port (instance -o streams here)
#   POSE_IDLE_EXIT   20           tap idle-exit seconds before re-ensuring
#   POSE_WAIT        60           per-attempt container wait (s, wait_for.sh)
#   POSE_TRIES       0            attempts before giving up (0 = forever;
#                                   validate.sh uses 1 for a fast timeout path)
#   POSE_TAP_ARGS                 extra pose_tap.py flags (--north-up etc.)
set -uo pipefail

POSE_CONTAINER="${POSE_CONTAINER:-px4-sitl-16}"
POSE_MAV_LOCAL="${POSE_MAV_LOCAL:-14590}"
POSE_MAV_PORT="${POSE_MAV_PORT:-14591}"
POSE_IDLE_EXIT="${POSE_IDLE_EXIT:-20}"
POSE_WAIT="${POSE_WAIT:-60}"
POSE_TRIES="${POSE_TRIES:-0}"

PX4_ROOTFS=/root/PX4-Autopilot/build/px4_sitl_default/rootfs
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { echo "[pose_tap.sh] $*"; }

tries=0
while :; do
    if [ "$POSE_TRIES" != 0 ]; then
        tries=$((tries + 1))
        if [ "$tries" -gt "$POSE_TRIES" ]; then
            say "giving up after $POSE_TRIES attempt(s)"
            exit 1
        fi
    fi
    if ! "$MYDIR/wait_for.sh" container "$POSE_CONTAINER" "$POSE_WAIT"; then
        sleep 2
        continue
    fi
    # ensure the dedicated instance. Check the bound port FIRST: a re-start on
    # a live instance is harmless but prints a red "port already occupied" on
    # the pxh console (mavlink client output lands on the SERVER console) —
    # scary noise during a genuine failure hunt. The port bound inside the
    # sim netns is the actual readiness signal either way.
    port_hex="$(printf '%04X' "$POSE_MAV_LOCAL")"
    if ! docker exec "$POSE_CONTAINER" grep -qi ":$port_hex" /proc/net/udp; then
        docker exec "$POSE_CONTAINER" bash -c \
            "cd $PX4_ROOTFS && ../bin/px4-mavlink start -x -u $POSE_MAV_LOCAL \
             -r 4000000 -m onboard -o $POSE_MAV_PORT" >/dev/null 2>&1
    fi
    if ! docker exec "$POSE_CONTAINER" grep -qi ":$port_hex" /proc/net/udp; then
        say "waiting for PX4 (dedicated mavlink :$POSE_MAV_LOCAL not up yet)"
        sleep 2
        continue
    fi
    say "dedicated mavlink instance :$POSE_MAV_LOCAL -> :$POSE_MAV_PORT ready"
    # shellcheck disable=SC2086  # POSE_TAP_ARGS is intentionally word-split
    python3 "$MYDIR/tools/pose_tap.py" --mav-port "$POSE_MAV_PORT" \
        --mav-remote "127.0.0.1:$POSE_MAV_LOCAL" \
        --idle-exit "$POSE_IDLE_EXIT" ${POSE_TAP_ARGS:-}
    say "tap exited (rc $?) — re-ensuring the instance"
    sleep 2
done
