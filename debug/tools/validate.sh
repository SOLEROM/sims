#!/bin/bash
# validate.sh — staged validation of the debug layer (collect-logs.sh).
#
#   ./validate.sh    # static -> no-match collect -> real collect against a
#                    # scratch container (--id, log content, inspect, manifest)
#                    # -> tarball. Needs docker + the ubuntu:24.04 image.
#
# Uses a throwaway container fgfs_97 (ID 97 to stay clear of live sims) and a
# scratch --out dir; removes both when done. Never touches real sim containers.
set -uo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$MYDIR")"                       # debug/
COLLECT="$BASE/collect-logs.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
step() { echo; echo "== $* =="; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/debug-validate.XXXXXX")"
cleanup() { docker rm -f fgfs_97 >/dev/null 2>&1; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 1. static --
step "static checks"
for f in "$COLLECT" "$MYDIR/validate.sh"; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
bash "$COLLECT" --help 2>/dev/null | grep -q "collect-logs.sh" \
    && ok "--help prints usage" || bad "--help"

# ------------------------------------------------- 2. no-match collection ----
step "collection with nothing matching (still yields a bundle + warning)"
OUT="$(COLLECT_PATTERNS=nosuchbase bash "$COLLECT" --out "$SCRATCH" --no-tar 2>&1)"
case "$OUT" in *"WARN: no sim containers matched"*) ok "warns on no match" ;; \
               *) bad "missing no-match warning" ;; esac
DEST="$(echo "$OUT" | sed -n 's/^\[collect\] -> //p' | head -1)"
[ -n "$DEST" ] && [ -f "$DEST/MANIFEST.txt" ] \
    && ok "manifest written ($DEST)" || bad "no manifest for empty run"
grep -q "NONE MATCHED" "$DEST/MANIFEST.txt" 2>/dev/null \
    && ok "manifest states NONE MATCHED explicitly" || bad "manifest hides the absence"
[ -f "$DEST/system/docker-ps.txt" ] \
    && ok "system snapshot present" || bad "system snapshot missing"

# --------------------------------------- 3. real collect, scratch container --
step "collection of a real container (fgfs_97, --id filter)"
docker rm -f fgfs_97 >/dev/null 2>&1
if docker run -d --name fgfs_97 ubuntu:24.04 bash -c 'echo hello-debug-97; sleep 300' >/dev/null 2>&1; then
    OUT="$(bash "$COLLECT" --id 97 --out "$SCRATCH" --no-tar 2>&1)"
    DEST="$(echo "$OUT" | sed -n 's/^\[collect\] -> //p' | head -1)"
    grep -q "hello-debug-97" "$DEST/docker/fgfs_97.log" 2>/dev/null \
        && ok "docker log captured with content" || bad "docker/fgfs_97.log content"
    grep -q '"Name": "/fgfs_97"' "$DEST/inspect/fgfs_97.json" 2>/dev/null \
        && ok "docker inspect captured" || bad "inspect/fgfs_97.json"
    grep -q "fgfs_97.log" "$DEST/MANIFEST.txt" 2>/dev/null \
        && ok "manifest lists the log + line count" || bad "manifest listing"
    grep -q "fgfs_97" "$DEST/system/docker-ps.txt" 2>/dev/null \
        && ok "docker-ps snapshot has the container" || bad "docker-ps snapshot"
    # --id must FILTER: a second scratch id is not collected
    docker rm -f fgfs_96 >/dev/null 2>&1
    docker run -d --name fgfs_96 ubuntu:24.04 sleep 300 >/dev/null 2>&1
    OUT2="$(bash "$COLLECT" --id 97 --out "$SCRATCH" --no-tar 2>&1)"
    DEST2="$(echo "$OUT2" | sed -n 's/^\[collect\] -> //p' | head -1)"
    [ -f "$DEST2/docker/fgfs_96.log" ] \
        && bad "--id 97 also collected fgfs_96" || ok "--id filters other ids out"
    docker rm -f fgfs_96 >/dev/null 2>&1
else
    bad "could not start scratch container fgfs_97 (docker? ubuntu:24.04 image?)"
fi

# ------------------------------------------------------------- 4. tarball ----
step "tarball"
OUT="$(bash "$COLLECT" --id 97 --out "$SCRATCH" 2>&1)"
TARBALL="$(echo "$OUT" | sed -n 's/^\[collect\] tarball: //p' | head -1)"
[ -n "$TARBALL" ] && [ -s "$TARBALL" ] && tar -tzf "$TARBALL" >/dev/null 2>&1 \
    && ok "tarball created + readable ($(basename "$TARBALL"))" || bad "tarball"

echo
echo "==================== $PASS passed, $FAIL failed ===================="
[ "$FAIL" = 0 ]
