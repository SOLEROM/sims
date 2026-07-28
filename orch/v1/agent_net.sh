#!/bin/bash
# agent_net.sh — per-vehicle network-namespace ANCHOR container "agent-$ID".
#
# The anchor is a tiny sleeping container that OWNS the vehicle's netns. Every
# service of the vehicle joins it (--network container:agent-$ID), so services
# can crash/restart freely without tearing down the vehicle's networking —
# unlike the "first heavy container owns the netns" model, where killing that
# container kills the whole vehicle's network (the netns-owner invariant).
#
# Because published ports must be declared by the netns owner, the anchor also
# carries the vehicle's host-side port map (AGENT_PUBLISH): internal ports stay
# IDENTICAL across vehicles (conventions §1), only the host edge is per-ID.
#
#   agent_net.sh up <ID>      create anchor agent-<ID> (idempotent: recreates)
#   agent_net.sh down <ID>    remove it
#   agent_net.sh status       list anchors
#
# Env:
#   ANCHOR_IMAGE    image for the anchor (default ubuntu:24.04 — already present
#                   on any station that built the sim layers)
#   AGENT_PUBLISH   space-separated "HOST:CONT[/udp]" publish specs; the token
#                   %ID% in the HOST part is replaced by the vehicle id, e.g.
#                   "1577%ID%:15777 1578%ID%:15778/udp" -> vehicle 2 publishes
#                   host 15772->15777(tcp) and 15782->15778(udp)
#   SIM_NET         extra bridge network to connect the anchor to (created by
#                   simrun.sh; skipped when unset or missing)
set -euo pipefail

ANCHOR_IMAGE="${ANCHOR_IMAGE:-ubuntu:24.04}"
CMDW="${1:-}"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,20p'; exit 2; }

case "$CMDW" in
up)
    ID="${2:-}"; [ -n "$ID" ] || usage
    NAME="agent-$ID"
    PUB_ARGS=()
    for spec in ${AGENT_PUBLISH:-}; do
        PUB_ARGS+=(-p "${spec//%ID%/$ID}")
    done
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --init --rm \
        --name "$NAME" \
        --hostname "$NAME" \
        --env ID="$ID" \
        ${PUB_ARGS[@]+"${PUB_ARGS[@]}"} \
        "$ANCHOR_IMAGE" sleep infinity >/dev/null
    if [ -n "${SIM_NET:-}" ] && docker network inspect "$SIM_NET" >/dev/null 2>&1; then
        docker network connect "$SIM_NET" "$NAME" 2>/dev/null || true
    fi
    echo "[agent_net] up: $NAME${AGENT_PUBLISH:+ (publish: ${AGENT_PUBLISH//%ID%/$ID})}${SIM_NET:+ + net $SIM_NET}"
    ;;
down)
    ID="${2:-}"; [ -n "$ID" ] || usage
    docker rm -f "agent-$ID" >/dev/null 2>&1 && echo "[agent_net] down: agent-$ID" \
        || echo "[agent_net] agent-$ID not running"
    ;;
status)
    docker ps --filter "name=^agent-" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
*)
    usage
    ;;
esac
