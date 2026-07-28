#!/bin/bash
# thin wrapper: objects.json -> .stg tree + .kml  (see gen_objects.py)
set -euo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$MYDIR/gen_objects.py" "$@"
