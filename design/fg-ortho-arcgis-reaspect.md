# FG ortho imagery ~50 m south shift — ArcGIS export re-aspects mismatched extents

Status: fixed + live-verified (2026-07-23). Code:
`fgear/craft_base_24/tools/gen_orthophotos.py` (`_aspect_size` / `_check_extent`
/ `fetch`).

## Observed

px4-fg live flight, vehicle at 373 ft AGL over UZH Irchel: QGC's map showed
the drone ON the campus building, the FG camera showed the building's corner
off to the side — the vehicle apparently ~50–60 m south-east of where QGC put
it. Vertical was fine (FG `/position/altitude-ft` 374.3 over ground at 0.2 m
vs QGC 373.3 ft AGL — within a foot). PX4 and FG agreed on lat/lon to ≤1e-6°,
and cropping `ortho_home.png` at the vehicle's exact lat/lon reproduced the FG
view — so the renderer was faithful and the TEXTURE was mis-georeferenced.

## Root cause

`fetch()` requested the home-quad bbox (0.0159° lon × 0.0108° lat = 1200 m ×
1200 m ground at 47.4°N) as a **square 2048×2048** image. The ArcGIS
`MapServer/export` endpoint silently **re-aspects the extent to the pixel
aspect** (centre kept). Replaying the exact request with `f=json` showed it:
requested lat span 0.010780° (1200 m), returned 0.015925° (**1773 m**). 1773 m
of latitude painted onto a 1200 m quad = N-S compression ×1.477; a feature
d metres south of home renders at d/1.477 — the vehicle 124 m south of the
anchor saw imagery from 183 m south (≈59 m error, growing linearly from the
anchor). E-W was untouched (lon span honored). The photoscenery tiles were
worse: 2:1-degree tile bboxes fetched square → lat coverage doubled.

## Decision

* `fetch()` computes the image height from the bbox's degree aspect
  (`h = round(px * dlat/dlon)`) and re-centres the bbox's lat span so extent
  ratio == w/h exactly — the provider has nothing to re-aspect. Returns
  `(img, bbox_actually_fetched)`; cache keys now carry `WxH` (old square
  entries can't be reused).
* One-shot `_check_extent()` guard per run: first network fetch replays the
  request with `f=json` and hard-errors if the provider adjusts the extent by
  more than one texel (`ORTHO_VERIFY=0` skips; probe network-flake only warns,
  cached offline runs never probe).
* Home quad stays `QUAD_HOME_M` square: the integer-pixel rounding residual is
  ≤ half a texel (~0.3 m), asserted ≤2 m. The quad geometry is NOT made
  rectangular — the .ac's −90° model↔world axis rotation would swap which
  ground axis gets which edge length (see `build_home_quad` docstring).
* Tiles stitch aspect-correct subs (2:1 tiles → e.g. 2048×1024 subs, exact)
  then resize the mosaic to the square power-of-two DDS — pure resampling,
  georeference unchanged.

## Verified

* `f=json` replay of the fixed request: returned extent == requested extent.
* Regenerated `ortho_home.png`: crop at the flight's vehicle lat/lon
  (47.396860, 8.546894) now shows the campus building under the crosshair,
  matching QGC.

## Rejected

* **`bboxSR=3857` (web-mercator) square requests** — avoids re-aspect
  naturally, but changes the georef math everywhere else in the layer
  (mercator-metre ≠ ground-metre at 47°N by the same ×1.477) for no accuracy
  gain over aspect-matched 4326 at these crop sizes.
* **Rectangular home quad sized from the fetched bbox** — sub-metre gain, but
  interacts with the .ac axis-rotation trap above; square + exact-span fetch
  is strictly safer.
* **Trusting `reaspect=false`-style flags** — `MapServer/export` has no such
  parameter (that's ImageServer's `adjustAspectRatio`); the f=json probe is
  provider-behavior-proof either way.

## Caveats

* Residual FG-vs-QGC offsets of a few metres are provider georegistration
  differences (Esri vs QGC's map source), not layer bugs.
* A custom `ORTHO_PROVIDER_URL` still using `{px},{px}` square sizes will
  re-trigger the bug — the extent probe catches it at run start if the
  template serves `f=image`.
