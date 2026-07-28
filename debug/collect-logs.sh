#!/bin/bash
# collect-logs.sh -- snapshot logs + state of a RUNNING (or just-finished) sim
# run into one timestamped folder so it can be inspected offline and shared.
# Read-only: cp / docker logs / docker inspect / props reads -- never starts,
# stops or mutates anything.
#
# It gathers, into a fresh timestamped folder:
#   docker/    `docker logs` of every sim container (conventions names over
#              COLLECT_PATTERNS bases: agent-<ID>, fgfs_<ID>, px4-sitl-16, ...)
#   inspect/   `docker inspect` JSON per container (env, mounts, nets, exit code)
#   fg/        best-effort FlightGear props snapshot per renderer (props telnet:
#              published port 1577<ID>, else host-net 15777)
#   px4/       the px4-fg flight-log bind mount (<root>/logs -> PX4 ulog etc.)
#   system/    docker ps -a, sim-net inspect, docker images, host + git info,
#              the layered env files (env.list, profiles/*.env, local.env)
#   MANIFEST.txt   index of everything collected (+ sizes)
# then tars it (unless --no-tar).
#
# COLLECT BEFORE RELAUNCHING: simrun.sh auto-runs clean.sh, which removes the
# containers -- and with them their docker logs.
#
# Usage:
#   ./debug/collect-logs.sh                 # collect everything -> /tmp
#   ./debug/collect-logs.sh --id 2          # only vehicle 2's containers
#   ./debug/collect-logs.sh --out ~/runs    # choose parent dir
#   ./debug/collect-logs.sh --no-tar        # leave the folder, skip the .tgz
#   ./debug/collect-logs.sh -h
set -uo pipefail

MYDIR="$(cd "$(dirname "$0")" && pwd)"                 # debug/
MYROOT="$(git -C "$MYDIR" rev-parse --show-toplevel 2>/dev/null || echo "$MYDIR/..")"
MYROOT="$(cd "$MYROOT" && pwd)"

OUTBASE="${TMPDIR:-/tmp}"
ONLY_ID=""
DO_TAR=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)     ONLY_ID="${2:-}"; shift 2 ;;
        --out)    OUTBASE="${2:-}"; shift 2 ;;
        --no-tar) DO_TAR=false; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUTBASE/sims-logs-$STAMP"
N=1  # same-second re-collects (e.g. validate.sh) must not merge into one bundle
while [[ -e "$DEST" ]]; do N=$((N+1)); DEST="$OUTBASE/sims-logs-$STAMP-$N"; done
mkdir -p "$DEST"/{docker,inspect,fg,px4,system/env}
echo "[collect] -> $DEST"

# container base names (same bases clean.sh tears down -- collect what a
# relaunch would destroy; override with COLLECT_PATTERNS / CLEAN_PATTERNS)
COLLECT_PATTERNS="${COLLECT_PATTERNS:-${CLEAN_PATTERNS:-agent fgfs px4-sitl}}"
SIM_NET="${SIM_NET:-sim-net}"
BASES="$(echo "$COLLECT_PATTERNS" | tr ' ' '|')"
IDPAT="${ONLY_ID:-[0-9]+}"
MATCH="^(${BASES})[-_](${IDPAT})$"

# -- 1) docker container logs + inspect ---------------------------------------
mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$MATCH" || true)
# the frozen px4 container is px4-sitl-16 -- the 16 is the PX4 version, not a
# vehicle id, so an --id filter would drop it; px4-fg is single-vehicle anyway
if [[ -n "$ONLY_ID" && "$ONLY_ID" != "16" ]] && \
   docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "px4-sitl-16"; then
    CONTAINERS+=("px4-sitl-16")
    echo "[collect] note: including px4-sitl-16 despite --id $ONLY_ID (16 = version, not a vehicle)"
fi
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "[collect] WARN: no sim containers matched${ONLY_ID:+ for ID=$ONLY_ID} ($MATCH)"
    echo "[collect]       already relaunched? simrun's auto-clean removes them (and their logs)."
fi
for c in "${CONTAINERS[@]}"; do
    echo "[collect] docker logs $c"
    docker logs "$c" > "$DEST/docker/$c.log" 2>&1 || \
        echo "(docker logs failed for $c)" >> "$DEST/docker/$c.log"
    docker inspect "$c" > "$DEST/inspect/$c.json" 2>&1 || true
done

# -- 2) FlightGear props snapshot (best-effort, machine-readable state) -------
# For each fgfs_<ID>: try the anchor-published host port 1577<ID> (fg-demo),
# then plain 15777 (host-net profiles like px4-fg).
FG_PROP="$MYROOT/fgear/craft_base_24/tools/fg_prop.py"
FG_PROPS="/sim/time/elapsed-sec /position/latitude-deg /position/longitude-deg
          /position/altitude-ft /orientation/heading-deg"
if [[ -f "$FG_PROP" ]] && command -v python3 >/dev/null; then
    for c in "${CONTAINERS[@]}"; do
        [[ "$c" =~ ^fgfs[-_]([0-9]+)$ ]] || continue
        FID="${BASH_REMATCH[1]}"
        for PORT in "1577$FID" 15777; do
            if timeout 8 python3 "$FG_PROP" --port "$PORT" get /sim/time/elapsed-sec >/dev/null 2>&1; then
                echo "[collect] fg props $c (port $PORT)"
                {
                    echo "# $c via props telnet port $PORT"
                    for p in $FG_PROPS; do
                        printf '%-28s %s\n' "$p" \
                            "$(timeout 8 python3 "$FG_PROP" --port "$PORT" get "$p" 2>/dev/null)"
                    done
                } > "$DEST/fg/$c.props.txt"
                break
            fi
        done
        [[ -f "$DEST/fg/$c.props.txt" ]] || \
            echo "[collect] note: $c props telnet not answering (1577$FID/15777) -- renderer down?"
    done
fi

# -- 3) PX4 flight logs (px4-fg bind mount <root>/logs) -----------------------
if [[ -d "$MYROOT/logs" ]] && [[ -n "$(ls -A "$MYROOT/logs" 2>/dev/null)" ]]; then
    echo "[collect] px4 flight logs ($MYROOT/logs)"
    cp -a "$MYROOT/logs/." "$DEST/px4/" 2>/dev/null || true
else
    echo "[collect] note: no px4 flight logs at $MYROOT/logs (fg-demo run, or PX4 never armed)"
fi

# -- 4) system snapshot -------------------------------------------------------
{
    echo "# host"; uname -a; echo; date -u +"collected_utc=%Y-%m-%dT%H:%M:%SZ"
    echo; echo "# git"; git -C "$MYROOT" rev-parse HEAD 2>/dev/null
    git -C "$MYROOT" status --short 2>/dev/null
} > "$DEST/system/host.txt" 2>&1
docker ps -a > "$DEST/system/docker-ps.txt" 2>&1 || true
docker network inspect "$SIM_NET" > "$DEST/system/$SIM_NET.json" 2>&1 || true
docker images > "$DEST/system/docker-images.txt" 2>&1 || true
# the layered env (what the run actually saw: env.list < profile.env < local.env)
cp -a "$MYROOT/orch/v1/env.list" "$DEST/system/env/" 2>/dev/null || true
cp -a "$MYROOT"/orch/v1/profiles/*.env "$DEST/system/env/" 2>/dev/null || true
[[ -f "$MYROOT/orch/v1/local.env" ]] && \
    cp -a "$MYROOT/orch/v1/local.env" "$DEST/system/env/" 2>/dev/null

# -- 5) manifest --------------------------------------------------------------
{
    echo "sims log collection"
    echo "collected: $STAMP"
    echo "root:      $MYROOT"
    echo "filter:    ${ONLY_ID:-<all ids>}"
    echo
    echo "container logs:"      # explicit, so 'absent' is never mistaken for 'fine'
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        echo "  NONE MATCHED (containers already cleaned? collect before relaunching)"
    fi
    for c in "${CONTAINERS[@]}"; do
        printf '  %-24s %s lines\n' "$c.log" "$(wc -l < "$DEST/docker/$c.log" 2>/dev/null || echo '?')"
    done
    echo
    echo "files:"
    ( cd "$DEST" && find . -type f -printf '  %10s  %p\n' 2>/dev/null \
        || find . -type f -exec ls -l {} \; )
} > "$DEST/MANIFEST.txt"

echo "[collect] manifest:"
sed 's/^/    /' "$DEST/MANIFEST.txt" | head -40

# -- 6) tar -------------------------------------------------------------------
if $DO_TAR; then
    TARBALL="$DEST.tgz"
    tar -czf "$TARBALL" -C "$OUTBASE" "$(basename "$DEST")" 2>/dev/null && \
        echo "[collect] tarball: $TARBALL"
fi

echo "[collect] done -> $DEST"
echo "[collect] debug: paste $MYDIR/debugPrompt.md to a new Claude session,"
echo "[collect]        give it LOG_FOLDER=$DEST + what looked wrong."
