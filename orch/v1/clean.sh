#!/bin/bash
# clean.sh — teardown of orchestrated sim containers + the shared bridge.
#
#   ./clean.sh          # remove ALL matching containers + the sim net
#   ./clean.sh 2        # remove only vehicle 2's containers
#   ./clean.sh -n       # dry-run (also: ./clean.sh -n 2)
#
# Matches the conventions naming rule (^<base>[-_]<ID>$) over the bases in
# CLEAN_PATTERNS (default: the anchor + the known layer bases). Named volumes
# (e.g. fgfs NavCache fgfs_home_$ID) are deliberately LEFT — remove manually
# with `docker volume rm` to force a cache rebuild.
set -euo pipefail

CLEAN_PATTERNS="${CLEAN_PATTERNS:-agent fgfs px4-sitl}"
SIM_NET="${SIM_NET:-sim-net}"

DRY=0; ONLY_ID=""
for a in "$@"; do
    case "$a" in
        -n) DRY=1 ;;
        *) [[ "$a" =~ ^[0-9]+$ ]] && ONLY_ID="$a" || { echo "usage: clean.sh [-n] [ID]"; exit 2; } ;;
    esac
done

BASES="$(echo "$CLEAN_PATTERNS" | tr ' ' '|')"
IDPAT="${ONLY_ID:-[0-9]+}"
REGEX="^(${BASES})[-_](${IDPAT})$"

mapfile -t VICTIMS < <(docker ps -a --format '{{.Names}}' | grep -E "$REGEX" || true)

if [[ ${#VICTIMS[@]} -eq 0 ]]; then
    echo "[clean] nothing matches $REGEX"
else
    for c in "${VICTIMS[@]}"; do
        if [[ "$DRY" = 1 ]]; then
            echo "[clean] would remove container: $c"
        else
            docker rm -f "$c" >/dev/null && echo "[clean] removed container: $c"
        fi
    done
fi

# the shared bridge goes only on a FULL clean (no ID filter)
if [[ -z "$ONLY_ID" ]] && docker network inspect "$SIM_NET" >/dev/null 2>&1; then
    if [[ "$DRY" = 1 ]]; then
        echo "[clean] would remove network: $SIM_NET"
    else
        docker network rm "$SIM_NET" >/dev/null 2>&1 \
            && echo "[clean] removed network: $SIM_NET" \
            || echo "[clean] network $SIM_NET busy (containers still attached?)"
    fi
fi
