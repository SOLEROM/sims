# px4-fg: Gazebo GUI window vs headless physics (`PX4_HEADLESS`)

*2026-07-23 — status: implemented (knob), validated via dry-run + shell test.*

## Observed

`./orch/v1/simrun.sh 1 --config px4-fg` popped a **separate Gazebo window** on
the desktop — unexpected, which raised the question: isn't Gazebo part of the
physics docker?

## Root cause

It is. Gazebo splits into a **server** (physics, `gz sim -s`) and an optional
**GUI client** (`gz sim -g`); the physics always runs inside the container.
The extra window was only the GUI client:

* `runGzPX4.sh` (frozen image) starts PX4 with `PX4_SIM_MODEL=gz_x500`, so
  PX4 v1.16's rcS runs `etc/init.d-posix/px4-rc.gzsim`, which does:

  ```sh
  gz sim ... -r -s "${PX4_GZ_WORLDS}/${PX4_GZ_WORLD}.sdf" &   # SERVER = physics
  if [ -z "${HEADLESS}" ]; then
      gz sim -g > /dev/null 2>&1 &                            # GUI window
  fi
  ```

* The frozen layer's `px4/px4_gazebo_16/run.sh` passes `DISPLAY` + the X11
  socket into the container (it predates the conventions, built for
  interactive use) — so the `gz sim -g` client succeeds and the window pops.

**Why the window is a surprise:** Gazebo-Classic-era SITL images commonly bake
`HEADLESS=1` into the container CMD, so they only ever launch the physics
server — no GUI client; QGC is the eyes. This image doesn't, and it gets a
working DISPLAY.

## Decision

Profile knob **`PX4_HEADLESS`**, default **1** (physics only, QGC as the
eyes), GUI on demand:

* `orch/v1/profiles/px4-fg.env` — `PX4_HEADLESS="${PX4_HEADLESS:-1}"`
  (`:-` keeps the layering contract: explicit env > env file > default;
  `local.env` overrides as usual).
* `orch/v1/profiles/terminator.run.px4-fg` `pxh` tab — the env is injected at
  `docker exec` time, translated to what PX4 actually checks (`-z HEADLESS`):

  ```
  docker exec -it -e HEADLESS=$([ "${PX4_HEADLESS:-1}" != 0 ] && echo 1) ...
  ```

  `PX4_HEADLESS=1` → `HEADLESS=1` (headless); `PX4_HEADLESS=0` →
  `HEADLESS=` empty → PX4's `[ -z ]` test passes → GUI window.

Usage: `PX4_HEADLESS=0` in `orch/v1/local.env` (or explicit env) when you
want to eyeball the world/model; the default run is physics-only.

## Rejected alternatives

* **Bake `HEADLESS=1` into the image / edit `runGzPX4.sh`** — the `px4/`
  layer is FROZEN (working rule #2); fixes go around it. `docker exec -e` is
  exactly that.
* **Hardcode headless in the tab line (no knob)** — the GUI is genuinely
  useful for eyeballing the gz world/model; a 0/1 knob in the existing env
  layering costs one line.
* **Strip DISPLAY from `run.sh`** — same frozen-layer objection, and it would
  also kill any future in-container GUI use.
