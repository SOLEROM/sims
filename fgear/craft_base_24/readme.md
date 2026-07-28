# craft_base_24 — generic FlightGear layer (ubuntu 24.04)

A reusable, project-agnostic FlightGear layer, generalized from a production
multi-drone sim (where every mechanism here was proven live). Two roles:

* **standalone** — plain FlightGear, FG flies itself. Scenery checks, exploring.
* **external-fdm** — the important one: a **"drone camera" renderer**. FlightGear
  does **no physics**; the vehicle pose streams IN over UDP (9-field generic
  protocol) and FG renders the world + a camera view an outer pipeline can
  screen-grab. N instances = N drone cameras, isolated by network namespace.

## Versions

| layer | base | FlightGear | notes |
|-------|------|-----------|-------|
| craft_base_20 | ubuntu:20.04 | 2019.1.1 (distro) | legacy, standalone only |
| **craft_base_24** | ubuntu:24.04 | saiarcot895 PPA | dual-mode; render fixes verified on this build |

## Files

```
Dockerfile.base     generic image: FG + xvfb (headless CI) + baked hooks; build
                    args SCENERY_TILES / AIRCRAFT_ZIPS (both optional)
build.sh            build wrapper (IMAGE_NAME, SCENERY_TILES, AIRCRAFT_ZIPS env)
run.sh              host-side docker runner: ID, network mode, FGFS_GPU backend,
                    xauth, NavCache volume, FG_ASSETS_DIR mounts
fgfs_runner.sh      in-container dual-mode launcher (FG_MODE), all knobs env-driven
protocol/fg_protocol.xml   9-field UDP pose input (baked; overridable)
nasal/addobj.nas    runtime object placement + ortho-ground auto-place (baked)
tools/
  fg_tiles.py       exact simgear SGBucket tile math (+ --selftest)
  gen_objects.py    objects.json -> per-tile .stg tree + ground-station .kml
  gen_orthophotos.py  satellite imagery: home ortho quad + photoscenery tiles
  feed_fdm.py       reference UDP pose sender (validation / bridge template)
  fg_prop.py        props-telnet get/set — scripted verification, no screenshots
  validate.sh       staged validation (static -> tiles -> generators -> dry-run
                    -> --build -> --image -> --live headless end-to-end)
assets.example/     example FG_ASSETS_DIR (objects.json at KSFO)
env.list.example    every knob + default, copy-paste ready
```

## Quick start

```bash
./build.sh                                  # lean base image (no scenery)
./run.sh                                    # standalone window
FG_MODE=external-fdm ./run.sh               # renderer, host net, KSFO default home
python3 tools/feed_fdm.py --lat 37.6135 --lon -122.3572 --alt-m 60 --circle-m 100 \
    --duration 60                           # fly the camera in a circle
python3 tools/fg_prop.py get /position/latitude-deg   # verify from a script
tools/validate.sh --all                     # full validation incl. live headless
```

Multi-instance (the agent model — a netns owner container per agent):

```bash
ID=2 FG_MODE=external-fdm FG_NET=container:px4-sitl-2 FG_ENV_FILE=env.list ./run.sh
```

## The external-fdm contract

| channel | default | direction | what |
|---------|---------|-----------|------|
| UDP `FG_GENERIC_PORT` 15778 | in | pose: 9 tab-separated `%f` fields (`fg_protocol`): cam-pitch-off, cam-roll-off, hdg, pitch, roll, lat, lon, **alt-ft**, view-hdg-off |
| TCP `FG_TELNET_PORT` 15777 | in/out | whole property tree (telnet props) — scripted asserts, runtime `/addobj` + `/ortho` control |
| UDP `FG_FDM_PORT` 5503 | in | native-fdm (legacy-compat; normally unused) |
| X11 window `FlightGear[-$ID]` | out | the camera view, titled per-ID so capture/placement tooling targets the right instance |

Field 9 (view azimuth), measured on this build: `screen_up_azimuth = heading −
heading_offset` (slope −1). Send `0` for heading-up/FPV; send `heading − TRIM`
to pin the window top at compass azimuth `TRIM` (north-up = ground-station
match). A wrong sign here makes the view spin at 2× heading.

## Project overlays

The base stays generic. A project adds its world two ways (combinable):

1. **Runtime mounts** — point `FG_ASSETS_DIR` at a dir with any of
   `Orthophotos/ Models/ Objects/ Nasal/ Protocol/ AI/` (mapping in the run.sh
   header; `Models/` appears as `Models/proj` in the FG tree). Live-editable.
2. **Overlay image** — `FROM fgfs-base:24` + `COPY` the same assets; or rebuild
   the base with `SCENERY_TILES="e030n30 e030n20"` / `AIRCRAFT_ZIPS="Rascal"`.

Generate the assets:

```bash
FG_HOME_LAT=.. FG_HOME_LON=.. tools/gen_orthophotos.sh --assets myassets/
tools/gen_objects.sh --json myassets/objects.json
```

## Render lessons (paid for in production — do not relearn)

* **`FGFS_GPU`: the ortho satellite ground only renders on HARDWARE GL.**
  FG renders via the host X server over the mounted socket, so the container's
  GL follows the host Xorg GPU. `intel|host` = plain docker + host-X GL (the
  blessed path on hybrid laptops; fast, correct). `1|auto` = NVIDIA passthrough
  only if a real nvidia runtime exists, else host-X GL. `0|sw` = llvmpipe:
  **slow (minutes of scenery build) AND the ortho ground does not draw** — it
  is a last resort, never a "fix" for a GPU station.
* **The ortho ground is placed at RUNTIME, not by static .stg.** A flat quad
  placed by an `.stg` `OBJECT_SHARED` line loads but never renders on this
  build; the identical model via `geo.put_model` renders fine. Hence
  `nasal/addobj.nas` auto-places it from `/ortho/*` props once
  `/sim/sceneryloaded`. Solid models (buoys/boxes) are fine from `.stg`.
* **Elevation is the whole game.** A flat plane is visible only from ABOVE it:
  it must sit just above local terrain and just **below the landed camera**
  (default `home_alt − 1 m`). Don't derive it from `geo.elevation()` for the
  explicit path — early in load it returns coarse values that re-bury the
  plane. Verify against the ortho PNG's features, never an RGB mean.
* **The draped quad renders its texture rotated 90°** from the naive
  "+X=East,−Z=North" `.ac` assumption, and a model heading arg does NOT fix it
  (axis convention, not yaw). The fix lives in the generated `.ac` UV refs
  (gen_orthophotos.py); the PNG stays north-up. Diagnose with the live
  COMPOSITE (grab the actual FG window at a known camera azimuth and compare to
  the PNG rotated 0/90/180/270) — camera quaternion and PNG can each look fine
  alone.
* **Square window on purpose.** A landscape window under a wide FOV pushes an
  extreme-oblique near-field wedge into frame, and downstream rescales stretch
  it; the square default (800×800) shows the clean nadir disc.
* **Per-ID window titles** (`/sim/title = FlightGear-$ID`): with N>1 every
  window is otherwise titled the same and first-match capture/placement tooling
  acts on instance 1's window for everyone.
* **NavCache (~166 MB) is persisted** per-ID in a named volume `fgfs_home_$ID`
  — only the first run pays the rebuild. `docker volume rm fgfs_home_<ID>`
  forces it.
* **Verify without screenshots**: everything observable lives in the props tree
  on telnet 15777 (`tools/fg_prop.py`). View azimuth can be read from
  `/sim/current-view/raw-orientation` (project the quaternion's +Y to ENU).

## Orchestration-readiness (see ../../CONVENTIONS.md)

`run.sh` follows the repo conventions so a future launcher (simrun-style
manifests) can drive it directly: the ONE per-instance variable is `ID`
(threaded purely through env), container name `fgfs_$ID`, internal ports
identical across instances (isolation by netns via `FG_NET=container:<owner>`),
config precedence env > env-file > default, and `--rm` + fresh-remove so a tab
restart is a clean relaunch.
