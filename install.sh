#!/bin/bash
# install.sh — one-shot, idempotent station setup for the sims repo.
#
# Makes sure everything needed to BUILD and RUN the docker layers is present:
#   1. host tools     (docker, terminator, python3 [+PIL/numpy], X11 helpers,
#                      QGC AppImage runtime deps + dialout group)
#   2. station env    (orch/v1/local.env from the example, never clobbered)
#   3. docker images  (fgfs-base:24, px4-sitl-16, anchor ubuntu:24.04)
#   4. image smoke checks
#
#   ./install.sh                # install what's missing, build missing images
#   ./install.sh --check        # report only, change nothing
#   ./install.sh --no-apt       # skip apt installs (just images)
#   ./install.sh --no-px4       # skip the (heavy) PX4 image
#   ./install.sh --no-fgfs      # skip the FlightGear image
#   ./install.sh --force-images # rebuild images even if they exist
#
# NOTE the PX4 image build is HEAVY: it clones PX4-Autopilot v1.16 with
# submodules and compiles SITL+gz inside docker — expect tens of minutes and a
# multi-GB image on first build. Logs: /tmp/sims_install_<image>.log
set -euo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$MYDIR"

CHECK=0; DO_APT=1; DO_PX4=1; DO_FGFS=1; FORCE=0
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        --no-apt) DO_APT=0 ;;
        --no-px4) DO_PX4=0 ;;
        --no-fgfs) DO_FGFS=0 ;;
        --force-images) FORCE=1 ;;
        *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done

ok()   { echo "  [OK]      $*"; }
miss() { echo "  [MISSING] $*"; }
act()  { echo "  [DO]      $*"; }

##############################################################################
# 1. host tools
##############################################################################
echo "== host tools =="
# cmd:apt-package pairs — REQUIRED for building/running the layers
REQ="git:git docker:docker.io terminator:terminator python3:python3 xhost:x11-xserver-utils xauth:xauth"
# optional niceties (validation window cleanup, proper DXT5 ortho encoding)
OPT="wmctrl:wmctrl nvcompress:nvidia-texture-tools"

APT_PKGS=()
for pair in $REQ; do
    c="${pair%%:*}"; p="${pair##*:}"
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else miss "$c (apt: $p)"; APT_PKGS+=("$p"); fi
done
APT_OPT=()
for pair in $OPT; do
    c="${pair%%:*}"; p="${pair##*:}"
    if command -v "$c" >/dev/null 2>&1; then ok "$c (optional)"; else miss "$c (optional, apt: $p)"; APT_OPT+=("$p"); fi
done
# python modules used by the ortho/objects generators
for mod in "PIL:python3-pil" "numpy:python3-numpy"; do
    m="${mod%%:*}"; p="${mod##*:}"
    if python3 -c "import $m" >/dev/null 2>&1; then ok "python3 $m"; else miss "python3 $m (apt: $p)"; APT_PKGS+=("$p"); fi
done
# QGC (ground control) runtime deps — QGC itself is an AppImage the user
# points QGC_CMD at in orch/v1/local.env; these let it run + show video.
# libfuse2t64 is the ubuntu 24.04 name of libfuse2 (AppImage mount support).
QGC_PKGS="gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gl
          python3-gi python3-gst-1.0 libfuse2t64
          libxcb-xinerama0 libxkbcommon-x11-0 libxcb-cursor-dev"
pkg_installed() { dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
for p in $QGC_PKGS; do
    if pkg_installed "$p"; then ok "$p (QGC)"; else miss "$p (QGC)"; APT_PKGS+=("$p"); fi
done

if [ ${#APT_PKGS[@]} -gt 0 ] || [ ${#APT_OPT[@]} -gt 0 ]; then
    if [ "$CHECK" = 1 ] || [ "$DO_APT" = 0 ]; then
        echo "  -> would apt install: ${APT_PKGS[*]:-} ${APT_OPT[*]:-}"
    else
        command -v apt-get >/dev/null || { echo "ERROR: no apt-get — install the missing tools manually"; exit 1; }
        act "sudo apt-get install ${APT_PKGS[*]:-} ${APT_OPT[*]:-}"
        sudo apt-get update -qq
        [ ${#APT_PKGS[@]} -gt 0 ] && sudo apt-get install -y "${APT_PKGS[@]}"
        [ ${#APT_OPT[@]} -gt 0 ] && { sudo apt-get install -y "${APT_OPT[@]}" || echo "  [WARN] optional packages failed (non-fatal)"; }
    fi
fi

# docker daemon usable by this user?
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "docker daemon reachable"
    else
        miss "docker daemon not reachable as $USER"
        if [ "$CHECK" = 0 ]; then
            act "adding $USER to the docker group (re-login to apply)"
            sudo usermod -aG docker "$USER" || true
            echo "  [WARN] log out/in (or 'newgrp docker') before building images"
        fi
    fi
fi

# serial-port access (QGC talking to real radios/telemetry over USB)
if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    ok "$USER in dialout group (QGC serial access)"
else
    miss "$USER not in dialout group (QGC serial access)"
    if [ "$CHECK" = 0 ]; then
        act "adding $USER to the dialout group (re-login to apply)"
        sudo usermod -aG dialout "$USER" || true
    fi
fi

##############################################################################
# 2. station env (untracked local.env from the example, never overwritten)
##############################################################################
echo "== station env =="
if [ -f orch/v1/local.env ]; then
    ok "orch/v1/local.env exists (kept as-is)"
elif [ "$CHECK" = 1 ]; then
    echo "  -> would create orch/v1/local.env from local.env.example"
else
    cp orch/v1/local.env.example orch/v1/local.env
    act "created orch/v1/local.env (edit FGFS_GPU etc. for this station)"
fi
if ! grep -qs '^\*\*/local\.env$' .gitignore; then
    if [ "$CHECK" = 1 ]; then
        echo "  -> would add **/local.env to .gitignore"
    else
        echo '**/local.env' >> .gitignore
        act "added **/local.env to .gitignore"
    fi
else
    ok ".gitignore covers local.env"
fi

##############################################################################
# 3. docker images
##############################################################################
echo "== docker images =="
have_image() { docker image inspect "$1" >/dev/null 2>&1; }

build_image() { # build_image <tag> <log-suffix> <build-command...>
    local tag="$1" logsfx="$2"; shift 2
    if have_image "$tag" && [ "$FORCE" = 0 ]; then
        ok "$tag present (use --force-images to rebuild)"
        return 0
    fi
    if [ "$CHECK" = 1 ]; then
        echo "  -> would build $tag:  $*"
        return 0
    fi
    local log="/tmp/sims_install_${logsfx}.log"
    act "building $tag (log: $log)"
    if "$@" >"$log" 2>&1; then
        ok "$tag built"
    else
        miss "$tag BUILD FAILED — tail of $log:"
        tail -15 "$log" | sed 's/^/      /'
        return 1
    fi
}

RC=0
# anchor image (tiny; also the base of fgfs-base so usually already present)
if have_image ubuntu:24.04; then
    ok "ubuntu:24.04 (netns anchor) present"
elif [ "$CHECK" = 1 ]; then
    echo "  -> would docker pull ubuntu:24.04"
else
    act "docker pull ubuntu:24.04"
    docker pull -q ubuntu:24.04 >/dev/null
fi

if [ "$DO_FGFS" = 1 ]; then
    build_image fgfs-base:24 fgfs \
        env -C "$MYDIR/fgear/craft_base_24" ./build.sh || RC=1
fi

if [ "$DO_PX4" = 1 ]; then
    # px4 layer is used AS-IS; both px4 variants document the same tag —
    # for the orchestrated px4-fg profile the GAZEBO (gz Harmonic) one is the
    # right owner of px4-sitl-16, so that is what we build here.
    build_image px4-sitl-16 px4 \
        docker build -f "$MYDIR/px4/px4_gazebo_16/Dockerfile.px4-sitl-gazebo" \
            -t px4-sitl-16 "$MYDIR/px4/px4_gazebo_16" || RC=1
fi

##############################################################################
# 4. image smoke checks
##############################################################################
echo "== image smoke =="
if [ "$DO_FGFS" = 1 ] && have_image fgfs-base:24; then
    V="$(docker run --rm -e QT_QPA_PLATFORM=offscreen fgfs-base:24 fgfs --version 2>/dev/null | head -1 || true)"
    [ -n "$V" ] && ok "fgfs-base:24: $V" || { miss "fgfs-base:24 smoke (fgfs --version)"; RC=1; }
fi
if [ "$DO_PX4" = 1 ] && have_image px4-sitl-16; then
    if docker run --rm px4-sitl-16 bash -lc \
        'test -x /root/PX4-Autopilot/runGzPX4.sh && test -x /root/PX4-Autopilot/build/px4_sitl_default/bin/px4' >/dev/null 2>&1; then
        ok "px4-sitl-16: px4 binary + runGzPX4.sh present"
    else
        miss "px4-sitl-16 smoke (px4 binary / runGzPX4.sh)"; RC=1
    fi
fi

echo
if [ "$CHECK" = 1 ]; then
    echo "check complete (nothing was changed)."
elif [ "$RC" = 0 ]; then
    echo "install complete. Try:  ./orch/v1/simrun.sh 2 --config fg-demo"
else
    echo "install finished WITH ERRORS — see messages above."
fi
exit "$RC"
