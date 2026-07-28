#!/bin/bash
# wait_for.sh — readiness probes for profile manifest lines (replaces raw
# `sleep` sequencing; conventions §6). All probes poll every 1s until success
# or timeout (default 120s), exit 0/1.
#
#   wait_for.sh container <name> [timeout]     docker container is Running
#   wait_for.sh tcp <host:port> [timeout]      TCP connect succeeds
#   wait_for.sh fg-telnet [port] [host] [timeout]
#                                              plain TCP connect to FG telnet
#                                              (default 15777 / 127.0.0.1)
#   wait_for.sh fg-props [port] [host] [timeout]
#                                              FG props telnet actually ANSWERS
#                                              a `get`. Use this through docker
#                                              PUBLISHED ports: docker-proxy
#                                              accepts TCP before the backend
#                                              listens, so plain tcp/fg-telnet
#                                              can false-positive there.
#
# Manifest usage example:
#   feed::./orch/v1/wait_for.sh fg-props 1577$ID && python3 tools/feed_fdm.py ...
set -euo pipefail

KIND="${1:-}"

poll() { # poll <timeout> <check-fn ...>
    local timeout="$1"; shift
    local t=0
    until "$@" 2>/dev/null; do
        t=$((t + 1))
        if [ "$t" -ge "$timeout" ]; then
            echo "[wait_for] TIMEOUT (${timeout}s): $*" >&2
            return 1
        fi
        sleep 1
    done
}

chk_container() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
chk_tcp()       { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && exec 3>&- 3<&-; }
chk_fg_props()  { # protocol-level: a `get` must come back with a value line
    python3 - "$1" "$2" <<'PY' 2>/dev/null
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3)
s.sendall(b"get /sim/time/elapsed-sec\r\n")
s.settimeout(3)
buf = b""
while b"\n" not in buf:
    c = s.recv(4096)
    if not c:
        break
    buf += c
sys.exit(0 if b"=" in buf else 1)
PY
}

case "$KIND" in
container)
    NAME="${2:?container name}"; TO="${3:-120}"
    poll "$TO" chk_container "$NAME" && echo "[wait_for] container $NAME up"
    ;;
tcp)
    HP="${2:?host:port}"; TO="${3:-120}"
    poll "$TO" chk_tcp "${HP%:*}" "${HP##*:}" && echo "[wait_for] tcp $HP up"
    ;;
fg-telnet)
    PORT="${2:-15777}"; HOST="${3:-127.0.0.1}"; TO="${4:-300}"
    poll "$TO" chk_tcp "$HOST" "$PORT" && echo "[wait_for] fg telnet $HOST:$PORT up"
    ;;
fg-props)
    PORT="${2:-15777}"; HOST="${3:-127.0.0.1}"; TO="${4:-300}"
    poll "$TO" chk_fg_props "$HOST" "$PORT" && echo "[wait_for] fg props $HOST:$PORT answering"
    ;;
*)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
