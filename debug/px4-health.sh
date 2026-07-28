#!/bin/bash
# px4-health.sh -- live "why can't I arm?" decoder for the px4-fg profile.
#
# pxh's "Arming denied: Resolve system health failures first" is a GENERIC
# message: the detailed per-check failures go out over the MAVLink events
# protocol (QGC sees them), not the console. This script asks the RUNNING
# px4-sitl-16 for the underlying uORB state (vehicle_status, failsafe_flags,
# health_report via the px4 client binaries) and prints, human-readable:
#   - vehicle state (mode, arming state, preflight pass/fail)
#   - health / arming-check failures decoded by component
#   - the per-mode requirement(s) blocking ARMING IN THE CURRENT MODE
#     (the actual reason behind the generic pxh denial)
#   - which modes COULD arm right now, and what to do about the blockers
#
# Read-only: uORB listeners + `commander check` only -- never sets params,
# never arms, never changes state.
#
# Usage:
#   ./debug/px4-health.sh              # default container px4-sitl-16
#   ./debug/px4-health.sh <container>  # another PX4 SITL container name
set -uo pipefail

CONTAINER="${1:-px4-sitl-16}"
PX4_DIR=/root/PX4-Autopilot
ROOTFS="$PX4_DIR/build/px4_sitl_default/rootfs"

fail() { echo "ERROR: $*" >&2; exit 1; }

# -- preconditions (container up, PX4 actually started) ---------------------
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
    || fail "container '$CONTAINER' is not running (profile not launched, or cleaned)"

if ! docker exec "$CONTAINER" pgrep -f 'bin/px4' >/dev/null 2>&1; then
    fail "PX4 is not running inside '$CONTAINER' -- the frozen image idles at bash;
       the 2_pxh tab must have run './runGzPX4.sh' (docker exec) first"
fi

px4ls() {  # px4ls <uorb_topic> -> one message dump (empty on timeout)
    timeout 8 docker exec "$CONTAINER" \
        bash -c "cd $ROOTFS && ../bin/px4-listener $1 -n 1" 2>/dev/null
}

VS="$(px4ls vehicle_status)"
FF="$(px4ls failsafe_flags)"
HR="$(px4ls health_report)"
[[ -n "$VS" && -n "$FF" ]] || fail "px4-listener returned nothing (PX4 still booting?)"

CHECK="$(timeout 8 docker exec "$CONTAINER" \
    bash -c "cd $ROOTFS && ../bin/px4-commander check" 2>&1 | tail -1)"

# -- sensor feed freshness: two uORB timestamp samples per sensor topic.
# A FROZEN timestamp while the sim runs = PX4's gz_bridge LOST that sensor
# (a zero-held-subscriber window severs the feed even though gz keeps
# publishing to new CLI subscribers — design/px4-fg-gz-sensor-keepalive.md).
# EKF/arming then fail, or the vehicle arms and sits on the ground. Only a
# PX4 restart (Ctrl-C in the pxh tab + a new ./runGzPX4.sh) re-subscribes.
FEED_TOPICS="sensor_accel sensor_gyro sensor_mag sensor_baro sensor_gps"
feed_ts() { px4ls "$1" | awk '/^[[:space:]]+timestamp:/{print $2; exit}'; }
declare -A _T1
for t in $FEED_TOPICS; do _T1[$t]="$(feed_ts "$t")"; done
sleep 1.2
FEEDS=""
for t in $FEED_TOPICS; do
    t2="$(feed_ts "$t")"
    if [ -z "${_T1[$t]}" ] && [ -z "$t2" ]; then v="NEVER PUBLISHED"
    elif [ "${_T1[$t]}" = "$t2" ]; then
        v="FROZEN — gz->PX4 feed severed; restart PX4 (Ctrl-C pxh, rerun ./runGzPX4.sh)"
    else v="alive"; fi
    FEEDS+="$t: $v"$'\n'
done

# nav_state number -> name, straight from the message definition in the image
NAVMSG="$(docker exec "$CONTAINER" bash -c \
    "cat $PX4_DIR/msg/versioned/VehicleStatus.msg 2>/dev/null || cat $PX4_DIR/msg/VehicleStatus.msg" 2>/dev/null)"

export VS FF HR CHECK NAVMSG FEEDS
python3 <<'PY'
import os, re, sys

def parse(dump):
    """'    key: value (extra)' lines -> {key: 'value'}"""
    out = {}
    for line in dump.splitlines():
        m = re.match(r'\s+(\w+): (.+)', line)
        if m:
            out[m.group(1)] = m.group(2).split(' (')[0].strip()
    return out

vs, ff, hr = (parse(os.environ[k]) for k in ('VS', 'FF', 'HR'))

nav_names = dict(
    (int(n), name) for name, n in
    re.findall(r'NAVIGATION_STATE_(\w+)\s*=\s*(\d+)', os.environ['NAVMSG'])
) or {0: 'MANUAL'}  # fallback if msg file not found

def nav_name(bit):
    return nav_names.get(bit, f'mode{bit}')

# libevents health_component_t bit -> name (stable upstream mapping)
COMPONENT = ['none', 'absolute_pressure', 'differential_pressure', 'gps',
             'optical_flow', 'vision_position', 'distance_sensor',
             'manual_control_input', 'motors_escs', 'utm', 'logging',
             'battery', 'communication_links', 'rate_controller',
             'attitude_controller', 'position_controller',
             'attitude_estimate', 'local_position_estimate', 'mission',
             'avoidance', 'system', 'camera', 'gimbal', 'payload',
             'global_position_estimate', 'storage']

def components(mask):
    mask = int(mask)
    return [COMPONENT[b] if b < len(COMPONENT) else f'bit{b}'
            for b in range(mask.bit_length()) if mask >> b & 1]

# failsafe_flags per-mode requirement mask <-> the flag that unmet-fails it
REQ = [
    ('mode_req_angular_velocity', 'angular_velocity_invalid', 'no valid gyro/rate data'),
    ('mode_req_attitude', 'attitude_invalid', 'no valid attitude estimate'),
    ('mode_req_local_alt', 'local_altitude_invalid', 'no valid local altitude'),
    ('mode_req_local_position', 'local_position_invalid', 'no valid local position'),
    ('mode_req_local_position_relaxed', 'local_position_invalid_relaxed', 'no valid local position (relaxed)'),
    ('mode_req_global_position', 'global_position_invalid', 'no valid global position'),
    ('mode_req_mission', 'auto_mission_missing', 'no mission uploaded'),
    ('mode_req_offboard_signal', 'offboard_control_signal_lost', 'no offboard setpoint stream'),
    ('mode_req_home_position', 'home_position_invalid', 'home position not set'),
    ('mode_req_manual_control', 'manual_control_signal_lost', 'no manual control input (no RC, no joystick)'),
]
HINT = {
    'manual_control_signal_lost':
        'enable QGC Virtual Joystick (Application Settings > Fly View), plug in\n'
        '      RC, or skip sticks entirely: pxh> commander takeoff',
    'auto_mission_missing': 'upload a mission in QGC first',
    'offboard_control_signal_lost': 'stream offboard setpoints before arming',
    'home_position_invalid': 'wait for EKF/GPS convergence (home is set automatically)',
}

def blockers(mode_bit):
    out = []
    for mask, flag, why in REQ:
        if int(ff.get(mask, 0)) >> mode_bit & 1 and ff.get(flag) == 'True':
            out.append((flag, why))
    if int(ff.get('mode_req_prevent_arming', 0)) >> mode_bit & 1:
        out.append((None, 'this mode never allows arming in it (RTL/Land/...)'))
    return out

nav = int(vs.get('nav_state', 0))
ARM_STATE = {1: 'STANDBY (disarmed)', 2: 'ARMED'}
print(f"container check : {os.environ['CHECK'].strip()}")
print(f"current mode    : {nav_name(nav)} (nav_state={nav})")
print(f"arming state    : {ARM_STATE.get(int(vs.get('arming_state', 0)), vs.get('arming_state'))}")
print(f"preflight pass  : {vs.get('pre_flight_checks_pass')}")

print("\n-- health report (bitmask decode) --")
if hr:
    for field in ('health_error_flags', 'health_warning_flags',
                  'arming_check_error_flags', 'arming_check_warning_flags'):
        names = components(hr.get(field, 0))
        print(f"{field:27s}: {', '.join(names) if names else '-'}")
    print("   (note: unmet per-MODE requirements are reported under 'system')")
else:
    print("health_report not available (topic silent)")

print("\n-- sensor feeds (uORB freshness, gz->PX4) --")
for line in os.environ['FEEDS'].strip().splitlines():
    print(f"  {line}")

print("\n-- raised failsafe/validity flags --")
raised = [k for k, v in ff.items()
          if v == 'True' and re.search(r'invalid|lost|missing|breach|failure|exceeded|unhealthy', k)]
print('\n'.join(f"  {k}" for k in raised) if raised else "  none")

print(f"\n-- why arming is denied in {nav_name(nav)} --")
blk = blockers(nav)
if not blk:
    print("  nothing blocks arming in the current mode.")
else:
    for flag, why in blk:
        print(f"  BLOCKER: {why}")
        if flag in HINT:
            print(f"      fix: {HINT[flag]}")

can_arm = int(hr.get('can_arm_mode_flags', 0))
armable = [nav_name(b) for b in range(can_arm.bit_length())
           if can_arm >> b & 1 and not nav_name(b).startswith(('FREE', 'mode'))]
print("\n-- modes that CAN arm right now --")
print('  ' + (', '.join(armable) if armable else 'none'))
PY
