#!/bin/bash
# validate.sh — staged validation of the orch/v1 orchestration layer.
#
#   ./validate.sh           # static + simrun dry-run plan + anchor lifecycle
#                           #   + wait_for + clean dry-run   (docker, no GUI)
#   ./validate.sh --live    # + REAL fg-demo boot: terminator windows on the
#                           #   current DISPLAY, 2 vehicles (renderers headless
#                           #   inside their containers), pose asserted via the
#                           #   anchors' published telnet ports, then clean.sh
#
# The live stage needs: DISPLAY, terminator, the fgfs-base:24 image.
set -uo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$MYDIR")"                       # orch/v1
ROOT="$(git -C "$BASE" rev-parse --show-toplevel)"
FGTOOLS="$ROOT/fgear/craft_base_24/tools"

DO_LIVE=0
[ "${1:-}" = "--live" ] && DO_LIVE=1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
step() { echo; echo "== $* =="; }

# ---------------------------------------------------------------- 1. static --
step "static checks"
for f in "$BASE"/*.sh "$MYDIR"/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

python3 -m py_compile "$MYDIR/pose_tap.py" 2>/dev/null \
    && ok "py_compile pose_tap.py" || bad "py_compile pose_tap.py"
python3 "$MYDIR/pose_tap.py" --selftest >/dev/null 2>&1 \
    && ok "pose_tap.py --selftest (CRC/framing/convert/loopback)" \
    || bad "pose_tap.py --selftest"

# ------------------------------------------------------- 2. simrun dry-run --
step "simrun dry-run plan (2 vehicles, fg-demo)"
PLAN="$(SIM_DRYRUN=1 bash "$BASE/simrun.sh" 2 --config fg-demo 2>&1)" || PLAN=""
for want in "agent_net.sh up 1" "agent_net.sh up 2" "vehicle02" \
            "docker network create" "DRYRUN> $BASE/clean.sh" \
            "1_fgfs::export ID=1" "2_feed::export ID=2" "3_info::" \
            "term_tabs.sh -t agent-1" "term_tabs.sh -t agent-2"; do
    case "$PLAN" in *"$want"*) ok "plan has: $want" ;; *) bad "plan missing: $want" ;; esac
done
PLAN2="$(SIM_DRYRUN=1 bash "$BASE/simrun.sh" 1 --config px4-fg 2>&1)" || PLAN2=""
case "$PLAN2" in *"agent_net.sh up"*) bad "px4-fg must skip anchors (SIM_NO_ANCHOR)" ;; \
                 *) ok "px4-fg skips anchors" ;; esac
case "$PLAN2" in *"3_keepalive::export ID=1; ./orch/v1/sensor_keepalive.sh"*) \
                     ok "px4-fg has sensor keepalive tab (3_keepalive)" ;; \
                 *) bad "px4-fg missing 3_keepalive tab" ;; esac
case "$PLAN2" in *"5_pose::export ID=1; ./orch/v1/pose_tap.sh"*) \
                     ok "px4-fg has pose tap tab (5_pose)" ;; \
                 *) bad "px4-fg missing 5_pose tab" ;; esac
PLAN3="$(SIM_DRYRUN=1 bash "$BASE/simrun.sh" 1 --no-clean 2>&1)" || PLAN3=""
case "$PLAN3" in *"skipping pre-run teardown"*) ok "--no-clean skips teardown" ;; \
                 *) bad "--no-clean not honored" ;; esac
bash "$BASE/simrun.sh" --help 2>/dev/null | grep -q "Usage: simrun.sh" \
    && ok "--help prints usage" || bad "--help"

# --------------------------------------------------- 3. anchor lifecycle ----
step "anchor lifecycle (agent-9, real docker)"
if AGENT_PUBLISH="1599%ID%:15777" bash "$BASE/agent_net.sh" up 9 >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Running}}' agent-9 2>/dev/null)" = "true" ] \
        && ok "agent-9 running" || bad "agent-9 not running"
    docker port agent-9 2>/dev/null | grep -q "15777/tcp -> .*:15999" \
        && ok "publish map %ID% substituted (15999->15777)" || bad "publish map"
    docker run --rm --network container:agent-9 ubuntu:24.04 true >/dev/null 2>&1 \
        && ok "netns joinable" || bad "netns join"
    bash "$BASE/agent_net.sh" down 9 >/dev/null 2>&1
    docker ps -a --format '{{.Names}}' | grep -qx agent-9 \
        && bad "agent-9 not removed" || ok "agent-9 removed"
else
    bad "agent_net.sh up 9"
fi

# --------------------------------------------------------- 4. wait_for ------
step "wait_for probes"
bash "$BASE/wait_for.sh" tcp 127.0.0.1:1 2 >/dev/null 2>&1 \
    && bad "tcp probe false-positive" || ok "tcp probe times out on closed port"
docker run -d --rm --name wfprobe ubuntu:24.04 sleep 30 >/dev/null 2>&1
bash "$BASE/wait_for.sh" container wfprobe 10 >/dev/null 2>&1 \
    && ok "container probe" || bad "container probe"
docker rm -f wfprobe >/dev/null 2>&1

# sensor_keepalive: bounded-retry path must give up (exit 1) on a missing container
KEEP_TRIES=1 KEEP_WAIT=2 KEEP_CONTAINER=no-such-container \
    bash "$BASE/sensor_keepalive.sh" >/dev/null 2>&1 \
    && bad "sensor_keepalive false success on missing container" \
    || ok "sensor_keepalive gives up after KEEP_TRIES on missing container"

# pose_tap.sh: same bounded-retry contract
POSE_TRIES=1 POSE_WAIT=2 POSE_CONTAINER=no-such-container \
    bash "$BASE/pose_tap.sh" >/dev/null 2>&1 \
    && bad "pose_tap.sh false success on missing container" \
    || ok "pose_tap.sh gives up after POSE_TRIES on missing container"

# --------------------------------------------------------- 5. clean dry-run --
step "clean.sh"
bash "$BASE/agent_net.sh" up 8 >/dev/null 2>&1
OUT="$(bash "$BASE/clean.sh" -n 8)"
case "$OUT" in *"would remove container: agent-8"*) ok "dry-run lists agent-8" ;; *) bad "dry-run: $OUT" ;; esac
bash "$BASE/clean.sh" 8 >/dev/null 2>&1
docker ps -a --format '{{.Names}}' | grep -qx agent-8 \
    && bad "clean.sh 8 left agent-8" || ok "clean.sh 8 removed agent-8"

# ------------------------------------------------------------- 6. live ------
if [ "$DO_LIVE" = 1 ]; then
    step "LIVE fg-demo: 2 vehicles, one terminator window each, pose via published ports"
    if [ -z "${DISPLAY:-}" ] || ! command -v terminator >/dev/null; then
        bad "live needs DISPLAY + terminator"
    else
        bash "$BASE/clean.sh" >/dev/null 2>&1
        # renderers headless INSIDE their containers (deterministic w.r.t. GL);
        # the terminator windows + anchors + netns + published ports are real
        FG_HEADLESS=1 bash "$BASE/simrun.sh" 2 --config fg-demo >/tmp/orch_live.log 2>&1 \
            && ok "simrun launched (see /tmp/orch_live.log)" || bad "simrun failed"
        for V in 1 2; do
            P=$((15770 + V))
            if bash "$BASE/wait_for.sh" fg-props "$P" 127.0.0.1 420 >/dev/null 2>&1; then
                ok "vehicle $V renderer answering (host port $P)"
                L1="$(python3 "$FGTOOLS/fg_prop.py" --port "$P" get /position/latitude-deg 2>/dev/null)"
                sleep 4
                L2="$(python3 "$FGTOOLS/fg_prop.py" --port "$P" get /position/latitude-deg 2>/dev/null)"
                if [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" != "$L2" ] && \
                   awk "BEGIN{exit !( ($L1-(${FG_HOME_LAT:-37.613544}))^2 < 0.0001 )}"; then
                    ok "vehicle $V pose circling near home ($L1 -> $L2)"
                else
                    bad "vehicle $V pose not moving/near home ($L1 -> $L2)"
                fi
            else
                bad "vehicle $V renderer never answered on $P"
            fi
        done
        # teardown: containers + net; close our windows best-effort
        bash "$BASE/clean.sh" >/dev/null 2>&1
        LEFT="$(docker ps -a --format '{{.Names}}' | grep -E '^(agent|fgfs)[-_][0-9]+$' || true)"
        [ -z "$LEFT" ] && ok "clean teardown (no sim containers left)" || bad "leftovers: $LEFT"
        docker network inspect sim-net >/dev/null 2>&1 \
            && bad "sim-net still present" || ok "sim-net removed"
        if command -v wmctrl >/dev/null; then
            wmctrl -F -c "agent-1" 2>/dev/null || true
            wmctrl -F -c "agent-2" 2>/dev/null || true
            ok "windows closed (wmctrl best-effort)"
        else
            echo "  [NOTE] no wmctrl — close the agent-1/agent-2 windows manually"
        fi
    fi
fi

echo
echo "==================== $PASS passed, $FAIL failed ===================="
[ "$FAIL" = 0 ]
