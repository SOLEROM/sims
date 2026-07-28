#!/bin/bash
# thin wrapper: satellite ortho quad + photoscenery tiles (see gen_orthophotos.py)
# Optionally source an env file first so FG_HOME_*/PX4_HOME_*/ORTHO_* match the
# sim:   ORTHO_ENV_FILE=path/to/env.list ./gen_orthophotos.sh --assets <dir>
set -euo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${ORTHO_ENV_FILE:-}" ] && [ -f "$ORTHO_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ORTHO_ENV_FILE" | sed 's/ *$//')
    set +a
fi
exec python3 "$MYDIR/gen_orthophotos.py" "$@"
