#!/bin/bash
# simrun.sh — boot N vehicles from a profile manifest (orch/v1).
#
# It first tears down any previous run (clean.sh — fresh run every time),
# then per vehicle ID=1..N:
#   1. creates the netns ANCHOR container agent-$ID (agent_net.sh: owns the
#      vehicle's network namespace + its host port map AGENT_PUBLISH)
#   2. connects the anchor to the shared bridge $SIM_NET (inter-vehicle net)
# and finally opens ONE Terminator window PER VEHICLE, titled
# "agent-<ID>", holding that vehicle's tab lines numbered "<seq>_<name>" (each
# tab exports its own ID — the only per-vehicle variable, conventions §2).
# The profile's "@once:" tabs (ground station etc., no ID set) join the FIRST
# vehicle's window, so no extra window pops.
#
# Profile = orch/v1/profiles/terminator.run.<name>   ("tab::command" lines,
#           "@once:tab::command" for run-once lines)
#         + optional orch/v1/profiles/<name>.env     (profile defaults)
#
# Env layering (later sources OVERRIDE earlier, all auto-exported):
#   orch/v1/env.list  <  profiles/<name>.env  <  orch/v1/local.env (untracked)
#
# Knobs: SIM_NET (default sim-net), SIM_NET_SUBNET (172.31.0.0/16),
#        SIM_NO_ANCHOR=1 (profile env: skip anchors, e.g. host-net profiles),
#        AGENT_PUBLISH (see agent_net.sh), SIM_DRYRUN=1.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: simrun.sh [N] [--config <profile>] [--no-clean]

  N                  number of vehicles (default 1)
  --config <name>    profile = orch/v1/profiles/terminator.run.<name>
                     (default px4-fg; see orch/v1/profiles/)
  --no-clean         skip the automatic clean.sh teardown before starting
  -h, --help         this help

Examples:
  ./simrun.sh                       # px4-fg (single vehicle), fresh (auto-clean)
  ./simrun.sh 3 --config fg-demo    # 3 vehicles of the renderer demo
  SIM_DRYRUN=1 ./simrun.sh          # print the full plan, touch nothing

Result: one Terminator window PER VEHICLE, titled "agent-<ID>", with numbered
tabs "<seq>_<name>" (the "@once:" tabs join agent-1's window). E.g. N=2:
  agent-1: 1_fgfs 2_feed 3_info      agent-2: 1_fgfs 2_feed
Teardown: orch/v1/clean.sh
EOF
}

MYDIR="${MYDIR:-$(cd "$(dirname "$0")" && pwd)}"
MYROOT="${MYROOT:-$(git -C "$MYDIR" rev-parse --show-toplevel 2>/dev/null || echo "$MYDIR/../..")}"
cd "$MYROOT"

##############################################################################
# arguments
##############################################################################
NUM_IDS=1
CONFIG="px4-fg"
NO_CLEAN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage; exit 0 ;;
        --config)
            CONFIG="${2:-}"
            [[ -n "$CONFIG" ]] || { echo "ERROR: --config requires value"; exit 1; }
            shift 2 ;;
        --no-clean)
            NO_CLEAN=1; shift ;;
        -*)
            echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            [[ "$1" =~ ^[0-9]+$ ]] || { echo "Invalid NUM_IDS: $1"; usage; exit 1; }
            NUM_IDS="$1"; shift ;;
    esac
done
[[ "$NUM_IDS" -ge 1 ]] || { echo "NUM_IDS must be >= 1"; exit 1; }

RUN_FILE="$MYDIR/profiles/terminator.run.${CONFIG}"
[[ -f "$RUN_FILE" ]] || { echo "Profile not found: $RUN_FILE"; exit 1; }

##############################################################################
# env layering: tracked shared env < profile defaults < station-local overrides
##############################################################################
for envf in "$MYDIR/env.list" "$MYDIR/profiles/${CONFIG}.env" "$MYDIR/local.env"; do
    if [[ -f "$envf" ]]; then
        echo "[INFO] sourcing ${envf#"$MYROOT"/}"
        set -a
        # shellcheck disable=SC1090
        . "$envf"
        set +a
    fi
done
export SIM_ENV_FILE="$MYDIR/env.list"
export NUM_IDS

SIM_NET="${SIM_NET:-sim-net}"
SIM_NET_SUBNET="${SIM_NET_SUBNET:-172.31.0.0/16}"
export SIM_NET

DRY="${SIM_DRYRUN:-0}"
run() {  # side-effect guard: echo in dry-run, execute otherwise
    if [[ "$DRY" = 1 ]]; then echo "DRYRUN> $*"; else "$@"; fi
}

echo "[INFO] NUM_IDS=$NUM_IDS CONFIG=$CONFIG NET=$SIM_NET"

##############################################################################
# split the manifest: per-vehicle tab lines vs @once: lines
##############################################################################
VEH_MANIFEST="$(mktemp)"; ONCE_MANIFEST="$(mktemp)"; TAB_MANIFEST="$(mktemp)"
trap 'rm -f "$VEH_MANIFEST" "$ONCE_MANIFEST" "$TAB_MANIFEST"' EXIT
while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if [[ "$trimmed" == @once:* ]]; then
        echo "${trimmed#@once:}" >> "$ONCE_MANIFEST"
    else
        echo "$trimmed" >> "$VEH_MANIFEST"
    fi
done < "$RUN_FILE"
[[ -s "$VEH_MANIFEST" ]] || { echo "ERROR: profile has no vehicle tab lines"; exit 1; }

##############################################################################
# fresh run: tear down leftovers of a previous run first
##############################################################################
if [[ "$NO_CLEAN" = 1 ]]; then
    echo "[INFO] --no-clean: skipping pre-run teardown"
else
    run "$MYDIR/clean.sh"
fi

##############################################################################
# shared bridge network (inter-vehicle; anchors connected by agent_net.sh)
##############################################################################
if [[ "$DRY" = 1 ]]; then
    echo "DRYRUN> docker network create --driver bridge --subnet $SIM_NET_SUBNET $SIM_NET (if missing)"
else
    docker network inspect "$SIM_NET" >/dev/null 2>&1 || \
        docker network create --driver bridge --subnet "$SIM_NET_SUBNET" "$SIM_NET" >/dev/null
fi

##############################################################################
# vehicles: netns anchor per ID (created BEFORE any tab runs)
##############################################################################
for ((ID=1; ID<=NUM_IDS; ID++)); do
    printf -v TAG "vehicle%02d" "$ID"
    if [[ "${SIM_NO_ANCHOR:-0}" != "1" ]]; then
        echo "[INFO] $TAG: netns anchor"
        run "$MYDIR/agent_net.sh" up "$ID"
    else
        echo "[INFO] $TAG: no anchor (SIM_NO_ANCHOR)"
    fi
done

##############################################################################
# terminator: ONE window PER VEHICLE, titled "agent-<ID>", tabs
# numbered inside the window "<seq>_<name>" (each tab exports its own ID);
# the @once: tabs join agent-1's window (no ID, no extra window)
##############################################################################
split_tab() {  # split_tab <manifest-line>  ->  sets name/cmd
    if [[ "$1" == *"::"* ]]; then
        name="${1%%::*}"; cmd="${1#*::}"
    else
        name="$1"; cmd="$1"
    fi
}
for ((ID=1; ID<=NUM_IDS; ID++)); do
    SEQ=0
    : > "$TAB_MANIFEST"
    while IFS= read -r line; do
        split_tab "$line"
        SEQ=$((SEQ+1))
        printf '%s_%s::export ID=%s; %s\n' "$SEQ" "$name" "$ID" "$cmd" >> "$TAB_MANIFEST"
    done < "$VEH_MANIFEST"
    if [[ "$ID" = 1 && -s "$ONCE_MANIFEST" ]]; then
        while IFS= read -r line; do
            split_tab "$line"
            SEQ=$((SEQ+1))
            printf '%s_%s::%s\n' "$SEQ" "$name" "$cmd" >> "$TAB_MANIFEST"
        done < "$ONCE_MANIFEST"
    fi
    if [[ "$DRY" = 1 ]]; then
        echo "---- window agent-$ID tabs ----"; sed 's/^/  /' "$TAB_MANIFEST"
        echo "DRYRUN> term_tabs.sh -t agent-$ID -f <tab-manifest>"
    else
        # term_tabs.sh reads the manifest fully before backgrounding terminator,
        # so the single temp file can be reused for the next vehicle
        "$MYDIR/term_tabs.sh" -t "agent-${ID}" -d "$MYROOT" -f "$TAB_MANIFEST"
    fi
done

echo "[INFO] done. teardown: orch/v1/clean.sh"
