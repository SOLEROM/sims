#!/usr/bin/env python3
"""gen_orthophotos.py — satellite imagery for the FlightGear renderer layer.

Generalized port of a proven in-house generator (host deps: python3 + Pillow +
numpy; no GDAL). Produces, under an assets dir (see run.sh FG_ASSETS_DIR):

  1. Models/ortho_home.{png,ac,xml} — THE RELIABLE PATH: a small home-centred
     ground quad textured with a high-res satellite crop. It is placed at
     RUNTIME by nasal/addobj.nas (props /ortho/*, fed by fgfs_runner.sh) —
     static .stg placement of flat quads loads but never renders on this FG
     build. Lessons encoded below in build_home_quad().
  2. Orthophotos/<10x10>/<1x1>/<index>.dds (+ .preview.png) — optional FG
     terrain photoscenery tiles (FG_PHOTOSCENERY=true). Known to render flat
     teal on some FG builds; kept because it is cheap and works elsewhere.

Imagery source: Esri World Imagery export endpoint (no API key, EPSG:4326 so a
bbox is already the lon/lat rectangle FG wants), fetched as a grid of
sub-requests and stitched. Override ORTHO_PROVIDER_URL for another provider.
The requested pixel size ALWAYS matches the bbox's degree aspect: the export
endpoint silently RE-ASPECTS a mismatched extent (see fetch()), which shifted
every feature away from the quad centre — design/fg-ortho-arcgis-reaspect.md.

Env / args (all optional):
  ORTHO_LAT, ORTHO_LON  AOI center (default FG_HOME_* -> PX4_HOME_* -> KSFO)
  ORTHO_ASSETS          assets dir to write into (default $PWD; --assets wins)
  ORTHO_TILES           explicit tile indices (else: the tile containing home)
  ORTHO_PX              photoscenery tile size px (default 4096)
  ORTHO_REQ_PX          max px per provider sub-request (default 2048)
  ORTHO_FORMAT          auto|dxt1|rgba|builtin (auto: nvcompress DXT5+mips via
                        host or docker; rgba is debug-only — FG warns
                        uncompressed DDS breaks rendering)
  ORTHO_QUAD            1 (default) also build the home quad; 0 tiles only
  ORTHO_QUAD_HOME_M     quad edge length, m (default 1200)
  ORTHO_QUAD_TEX_PX     quad texture size (default 2048)
  ORTHO_QUAD_UFLIP/VFLIP  mirror the quad texture E<->W / N<->S if needed
  ORTHO_VFLIP           store photoscenery tiles bottom-up
  ORTHO_CACHE           fetch cache dir (default /tmp/fg_orthocache)
  ORTHO_PROVIDER_URL    imagery export URL template ({bbox}/{w}/{h}
                        placeholders; legacy {px} = width)
  ORTHO_VERIFY          1 (default) f=json-probe the provider once per run to
                        assert it honors the requested extent; 0 skips
"""
import argparse
import io
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import urllib.request

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fg_tiles  # noqa: E402


def _env_home(name, fallback, default):
    v = os.environ.get("ORTHO_" + name) or os.environ.get("FG_HOME_" + name) \
        or os.environ.get("PX4_HOME_" + name) or default
    return float(str(v).strip())


HOME_LAT = _env_home("LAT", None, "37.613544")
HOME_LON = _env_home("LON", None, "-122.357172")
PX = int(os.environ.get("ORTHO_PX", "4096"))
REQ_PX = int(os.environ.get("ORTHO_REQ_PX", "2048"))
VFLIP = os.environ.get("ORTHO_VFLIP", "0") == "1"
FORMAT = os.environ.get("ORTHO_FORMAT", "auto").lower()
QUAD = os.environ.get("ORTHO_QUAD", "1") == "1"
QUAD_TEX_PX = int(os.environ.get("ORTHO_QUAD_TEX_PX", "2048"))
QUAD_HOME_M = float(os.environ.get("ORTHO_QUAD_HOME_M", "1200"))
QUAD_UFLIP = os.environ.get("ORTHO_QUAD_UFLIP", "0") == "1"
QUAD_VFLIP = os.environ.get("ORTHO_QUAD_VFLIP", "0") == "1"
CACHE = os.environ.get("ORTHO_CACHE", "/tmp/fg_orthocache")
NVTT_IMAGE = os.environ.get("ORTHO_NVTT_IMAGE", "ubuntu:24.04")

PROVIDER_URL = os.environ.get("ORTHO_PROVIDER_URL") or (
    "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export"
    "?bbox={bbox}&bboxSR=4326&imageSR=4326&size={w},{h}&format=jpg&f=image")


# ---------------------------------------------------------------------------
# imagery fetch + stitch
# ---------------------------------------------------------------------------
def _aspect_size(bbox, px):
    """(w, h, bbox'): pixel size whose aspect matches bbox's DEGREE aspect,
    plus the bbox with its lat span re-centred so extent ratio == w/h EXACTLY
    (integer-pixel rounding absorbed in the lat span: <=half a texel)."""
    lon0, lat0, lon1, lat1 = bbox
    h = max(1, round(px * (lat1 - lat0) / (lon1 - lon0)))
    lat_c = (lat0 + lat1) / 2.0
    lat_half = (lon1 - lon0) * h / px / 2.0
    return px, h, (lon0, lat_c - lat_half, lon1, lat_c + lat_half)


_extent_checked = False


def _check_extent(bbox, w, h):
    """One-shot guard (first NETWORK fetch of a run): ask the provider via
    f=json which extent it will actually render. The ArcGIS export silently
    RE-ASPECTS a bbox whose degree aspect mismatches the size=WxH pixel aspect
    (observed live: 1200 m lat span returned as 1773 m -> ~50 m ground shift
    at the quad edge). fetch() matches the aspect exactly, so any adjustment
    reported here is a provider behavior change -> hard error, never silently
    shifted imagery. Probe failures (network flake, non-JSON provider) only
    warn: the image fetch right after surfaces real outages."""
    global _extent_checked
    if _extent_checked or os.environ.get("ORTHO_VERIFY", "1") != "1" \
            or "f=image" not in PROVIDER_URL:
        return
    url = PROVIDER_URL.format(bbox="%.8f,%.8f,%.8f,%.8f" % bbox,
                              w=w, h=h, px=w).replace("f=image", "f=json")
    req = urllib.request.Request(url, headers={"User-Agent": "fg-orthogen/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            ext = json.load(r)["extent"]
        got = (ext["xmin"], ext["ymin"], ext["xmax"], ext["ymax"])
    except Exception as e:
        print(f"    (extent probe skipped: {type(e).__name__})")
        return
    tol = (bbox[2] - bbox[0]) / w                     # one texel, in degrees
    if any(abs(g - b) > tol for g, b in zip(got, bbox)):
        raise RuntimeError(
            f"provider re-aspected the extent: requested {bbox}, got {got} "
            "-- every texture would be mis-georeferenced (ORTHO_VERIFY=0 "
            "overrides, at your own risk)")
    _extent_checked = True
    print("    extent probe ok (provider honors the bbox)")


def fetch(bbox, px, tries=4):
    """Fetch bbox (lon0, lat0, lon1, lat1; EPSG:4326) as a px-wide image whose
    HEIGHT follows the bbox's degree aspect (see _aspect_size / _check_extent —
    a square request for a non-square-degree bbox gets silently re-aspected by
    the provider). Returns (img, bbox_actually_fetched)."""
    w, h, bbox = _aspect_size(bbox, px)
    os.makedirs(CACHE, exist_ok=True)
    key = "img_%s_%dx%d.jpg" % ("_".join("%.6f" % v for v in bbox), w, h)
    cached = os.path.join(CACHE, key)
    if os.path.exists(cached) and os.path.getsize(cached) > 1024:
        img = Image.open(cached).convert("RGB")
        if img.size == (w, h):
            return img, bbox
    _check_extent(bbox, w, h)
    url = PROVIDER_URL.format(bbox="%.8f,%.8f,%.8f,%.8f" % bbox, w=w, h=h, px=w)
    req = urllib.request.Request(url, headers={"User-Agent": "fg-orthogen/1.0"})
    last = None
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                data = r.read()
            img = Image.open(io.BytesIO(data)).convert("RGB")
            if img.size != (w, h):
                raise RuntimeError(f"provider returned {img.size}, "
                                   f"requested {(w, h)}")
            with open(cached, "wb") as f:
                f.write(data)
            return img, bbox
        except Exception as e:  # transient network/endpoint flakiness
            last = e
            print(f"    (retry {attempt + 1}/{tries} after {type(e).__name__})")
    raise RuntimeError(f"fetch failed for bbox {bbox}: {last}")


def build_tile(index):
    lon0, lat0, lon1, lat1 = fg_tiles.tile_bbox(index)
    grid = max(1, math.ceil(PX / REQ_PX))
    sub = PX // grid
    eff = sub * grid
    dlon = (lon1 - lon0) / grid
    dlat = (lat1 - lat0) / grid
    # sub height follows the tile's degree aspect (FG tile spans are exact
    # power-of-two degree ratios, so sub_h is exact and rows stay contiguous);
    # the final square resize just resamples — georeference is unchanged.
    sub_h = _aspect_size((lon0, lat0, lon0 + dlon, lat0 + dlat), sub)[1]
    print(f"  tile {index}: bbox lon[{lon0:.5f},{lon1:.5f}] lat[{lat0:.5f},{lat1:.5f}] "
          f"-> {PX}px ({grid}x{grid} grid of {sub}x{sub_h}px)")
    mosaic = Image.new("RGB", (eff, sub_h * grid))
    for r in range(grid):          # r=0 is the TOP row = NORTH (max lat)
        for c in range(grid):
            sb = (lon0 + c * dlon,
                  lat1 - (r + 1) * dlat,
                  lon0 + (c + 1) * dlon,
                  lat1 - r * dlat)
            img, _ = fetch(sb, sub)
            if img.size != (sub, sub_h):
                img = img.resize((sub, sub_h), Image.BILINEAR)
            mosaic.paste(img, (c * sub, r * sub_h))
            print(f"    sub r{r}c{c} ok")
    if mosaic.size != (PX, PX):
        mosaic = mosaic.resize((PX, PX), Image.BILINEAR)
    return mosaic, (lon0, lat0, lon1, lat1)


# ---------------------------------------------------------------------------
# DDS writers. FlightGear/osg want a COMPRESSED, MIP-MAPPED DDS (DXT5/BC3) like
# every stock FG .dds; a hand-rolled DXT1 without mipmaps loads silently as
# nothing -> untextured/teal terrain. Prefer nvcompress (nvidia-texture-tools),
# host first, then a throwaway docker container; built-in DXT1 is the last
# resort (and warned about).
# ---------------------------------------------------------------------------
def _to565(c):
    c = c.astype(np.uint16)
    return ((c[..., 0] >> 3) << 11) | ((c[..., 1] >> 2) << 5) | (c[..., 2] >> 3)


def _from565(v):
    r = ((v >> 11) & 0x1F).astype(np.float32) * (255.0 / 31)
    g = ((v >> 5) & 0x3F).astype(np.float32) * (255.0 / 63)
    b = (v & 0x1F).astype(np.float32) * (255.0 / 31)
    return np.stack([r, g, b], axis=-1)


def _encode_dxt1(rgb):
    """Vectorized BC1/DXT1 encoder (bounding-box endpoints). rgb (H,W,3) uint8,
    H/W multiples of 4. Returns raw block bytes (8 bytes / 4x4 block)."""
    h, w = rgb.shape[:2]
    bh, bw = h // 4, w // 4
    out = np.empty((bh, bw, 8), dtype=np.uint8)
    STEP = 64  # block-rows per chunk (caps memory)
    for r0 in range(0, bh, STEP):
        r1 = min(bh, r0 + STEP)
        band = rgb[r0 * 4:r1 * 4]                                   # (rows,w,3)
        blk = (band.reshape(r1 - r0, 4, bw, 4, 3)
               .transpose(0, 2, 1, 3, 4)
               .reshape(r1 - r0, bw, 16, 3).astype(np.float32))     # (n,bw,16,3)
        cmax = blk.max(axis=2); cmin = blk.min(axis=2)
        c0 = _to565(cmax); c1 = _to565(cmin)
        swap = c0 < c1
        c0, c1 = np.where(swap, c1, c0), np.where(swap, c0, c1)     # force 4-color mode
        p0 = _from565(c0); p1 = _from565(c1)
        pal = np.stack([p0, p1, (2 * p0 + p1) / 3.0, (p0 + 2 * p1) / 3.0], axis=2)
        d = blk[:, :, :, None, :] - pal[:, :, None, :, :]
        idx = (d * d).sum(-1).argmin(axis=3).astype(np.uint32)      # (n,bw,16)
        packed = (idx << (np.arange(16, dtype=np.uint32) * 2)).sum(axis=2).astype(np.uint32)
        o = out[r0:r1]
        o[..., 0] = c0 & 0xFF; o[..., 1] = (c0 >> 8) & 0xFF
        o[..., 2] = c1 & 0xFF; o[..., 3] = (c1 >> 8) & 0xFF
        o[..., 4] = packed & 0xFF; o[..., 5] = (packed >> 8) & 0xFF
        o[..., 6] = (packed >> 16) & 0xFF; o[..., 7] = (packed >> 24) & 0xFF
    return out.tobytes()


def _dds_header(h, w, fourcc, linear_size):
    DDSD = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000        # CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE
    hdr = struct.pack("<4sIIIIIII44xIIIIIIIIIIIII",
                      b"DDS ", 124, DDSD, h, w, linear_size, 0, 0,
                      32, 0x4, struct.unpack("<I", fourcc)[0], 0, 0, 0, 0, 0,  # DDPF_FOURCC
                      0x1000, 0, 0, 0, 0)
    assert len(hdr) == 128, len(hdr)
    return hdr


def _crop4(rgb):
    h, w = rgb.shape[:2]
    return rgb[:h - h % 4, :w - w % 4]


def _nvcompress_host(png, out, bc):
    if not shutil.which("nvcompress"):
        return False
    try:
        subprocess.run(["nvcompress", "-" + bc, "-silent", png, out], check=True)
        print(f"    encoded via host nvcompress -{bc} (+mipmaps)")
        return True
    except Exception as e:
        print(f"    host nvcompress failed: {e}")
        return False


def _nvcompress_docker(png, out, bc):
    if not shutil.which("docker"):
        return False
    d = os.path.dirname(os.path.abspath(out))
    sh = ("command -v nvcompress >/dev/null || { export DEBIAN_FRONTEND=noninteractive; "
          "apt-get update -qq && apt-get install -y -qq nvidia-texture-tools; } >/dev/null 2>&1; "
          f"nvcompress -{bc} /w/{os.path.basename(png)} /w/{os.path.basename(out)}")
    try:
        subprocess.run(["docker", "run", "--rm", "-v", f"{d}:/w", NVTT_IMAGE, "bash", "-c", sh],
                       check=True)
        ok = os.path.exists(out)
        if ok:
            print(f"    encoded via docker nvcompress -{bc} (+mipmaps, image {NVTT_IMAGE})")
        return ok
    except Exception as e:
        print(f"    docker nvcompress failed: {e}")
        return False


def write_dds(path, img):
    rgb = _crop4(np.asarray(img.convert("RGB"), dtype=np.uint8))   # row0=top=north
    if VFLIP:
        rgb = rgb[::-1]
    if FORMAT == "rgba":   # debug only -- FG warns uncompressed DDS breaks rendering
        h, w = rgb.shape[:2]
        bgra = np.dstack([rgb[..., 2], rgb[..., 1], rgb[..., 0],
                          np.full((h, w), 255, np.uint8)])
        hdr = struct.pack("<4sIIIIIII44xIIIIIIIIIIIII", b"DDS ", 124,
                          0x1 | 0x2 | 0x4 | 0x1000 | 0x8, h, w, w * 4, 0, 0,
                          32, 0x41, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000, 0x1000, 0, 0, 0, 0)
        with open(path, "wb") as f:
            f.write(hdr); f.write(bgra.tobytes())
        return
    bc = "bc1" if FORMAT == "dxt1" else "bc3"        # bc3=DXT5 (matches stock FG)
    png = path + ".tmp.png"
    Image.fromarray(rgb).save(png)
    try:
        if FORMAT != "builtin":
            if _nvcompress_host(png, path, bc):
                return
            if _nvcompress_docker(png, path, bc):
                return
        print("    WARNING: no nvcompress (host or docker); writing built-in DXT1 "
              "WITHOUT mipmaps -- many FG builds render this as flat/teal ground. "
              "Install nvidia-texture-tools (apt) for a proper orthophoto.")
        h, w = rgb.shape[:2]
        data = _encode_dxt1(rgb)
        with open(path, "wb") as f:
            f.write(_dds_header(h, w, b"DXT1", len(data)))
            f.write(data)
    finally:
        if os.path.exists(png):
            os.unlink(png)


def build_home_quad(models_dir):
    """Emit Models/ortho_home.{png,ac,xml}: a small flat ground plane of edge
    QUAD_HOME_M, CENTRED ON HOME, textured with a high-res satellite crop.

    Rules learned live (do not "simplify" these away):
      * SMALL crop CENTRED ON HOME, placed AT HOME — a whole-tile quad placed at
        the tile centre gets distance-culled near home and spans terrain of many
        elevations (buried in places, floating in others).
      * The .ac UV refs are rotated -90 deg from the naive U=East/V=North: FG's
        geo.put_model / OBJECT_SHARED orients a draped quad 90 deg from the
        assumed "+X=East,-Z=North" axis convention. A model heading arg does NOT
        fix it (the rotation is model<->world axes, not yaw). The PNG itself
        stays a normal north-up crop so it still matches the ground station.
      * The provider RE-ASPECTS mismatched requests: fetching this non-square-
        degree bbox as a square image returned 1773 m of latitude labelled as
        1200 m -> everything south of home rendered ~50 m too far south.
        fetch() matches the pixel aspect to the bbox (and f=json-verifies);
        the residual lat-span rounding is <=half a texel, so the quad safely
        stays QUAD_HOME_M square (asserted below).
      * Placement (position + elevation) happens at RUNTIME via nasal/addobj.nas
        — see that file for why static .stg placement never draws."""
    half = QUAD_HOME_M / 2.0
    mlat = 111320.0
    mlon = 111320.0 * math.cos(math.radians(HOME_LAT))
    bbox = (HOME_LON - half / mlon, HOME_LAT - half / mlat,
            HOME_LON + half / mlon, HOME_LAT + half / mlat)
    img, used = fetch(bbox, QUAD_TEX_PX)
    ew_m = (used[2] - used[0]) * mlon
    ns_m = (used[3] - used[1]) * mlat
    print(f"  home quad: {QUAD_HOME_M:.0f}m crop centred on {HOME_LAT:.5f},{HOME_LON:.5f} "
          f"(fetched {ew_m:.1f}x{ns_m:.1f} m, ~{QUAD_HOME_M / QUAD_TEX_PX:.2f} m/texel)")
    if abs(ew_m - QUAD_HOME_M) > 2.0 or abs(ns_m - QUAD_HOME_M) > 2.0:
        raise RuntimeError(
            f"home-quad crop covers {ew_m:.1f}x{ns_m:.1f} m but the quad is "
            f"{QUAD_HOME_M:.0f} m square -- imagery would be mis-placed")
    os.makedirs(models_dir, exist_ok=True)
    tex = img if img.size == (QUAD_TEX_PX, QUAD_TEX_PX) else img.resize(
        (QUAD_TEX_PX, QUAD_TEX_PX), Image.LANCZOS)
    if QUAD_UFLIP:
        tex = tex.transpose(Image.FLIP_LEFT_RIGHT)
    if QUAD_VFLIP:
        tex = tex.transpose(Image.FLIP_TOP_BOTTOM)
    tex.convert("RGB").save(os.path.join(models_dir, "ortho_home.png"))
    # verts: NW, NE, SE, SW (X=East, Z=South so North=-Z); UV refs = the naive
    # (0,1)(1,1)(1,0)(0,0) rotated -90 deg (see docstring).
    ac = f"""AC3Db
MATERIAL "ortho" rgb 1 1 1  amb 1 1 1  emis 0.9 0.9 0.9  spec 0 0 0  shi 0  trans 0
OBJECT world
kids 1
OBJECT poly
name "ortho_home"
texture "ortho_home.png"
loc 0 0 0
numvert 4
{-half:.1f} 0 {-half:.1f}
{half:.1f} 0 {-half:.1f}
{half:.1f} 0 {half:.1f}
{-half:.1f} 0 {half:.1f}
numsurf 1
SURF 0x30
mat 0
refs 4
0 1 1
1 1 0
2 0 0
3 0 1
kids 0
"""
    with open(os.path.join(models_dir, "ortho_home.ac"), "w") as f:
        f.write(ac)
    with open(os.path.join(models_dir, "ortho_home.xml"), "w") as f:
        f.write('<?xml version="1.0"?>\n'
                '<!-- generated home-centred ground orthophoto quad -->\n'
                '<PropertyList>\n  <path>ortho_home.ac</path>\n</PropertyList>\n')
    print(f"  wrote {models_dir}/ortho_home.{{png,ac,xml}} "
          f"({QUAD_HOME_M:.0f}x{QUAD_HOME_M:.0f} m, {QUAD_TEX_PX}px tex)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--assets", default=os.environ.get("ORTHO_ASSETS", os.getcwd()),
                    help="assets dir (gets Orthophotos/ + Models/)")
    ap.add_argument("tiles", nargs="*", help="explicit tile indices (optional)")
    args = ap.parse_args()

    assets = os.path.abspath(args.assets)
    tiles = args.tiles or (os.environ.get("ORTHO_TILES", "").replace(",", " ").split())
    idxs = [int(t) for t in tiles] if tiles else [fg_tiles.tile_index(HOME_LON, HOME_LAT)]

    print(f"AOI center {HOME_LAT},{HOME_LON}  assets={assets}")
    for idx in idxs:
        lon0, lat0, lon1, lat1 = fg_tiles.tile_bbox(idx)
        d10, d1 = fg_tiles.tile_dirs((lon0 + lon1) / 2, (lat0 + lat1) / 2)
        outdir = os.path.join(assets, "Orthophotos", d10, d1)
        os.makedirs(outdir, exist_ok=True)
        img, _ = build_tile(idx)
        dds = os.path.join(outdir, f"{idx}.dds")
        write_dds(dds, img)
        img.save(os.path.join(outdir, f"{idx}.preview.png"))
        print(f"  wrote {dds} ({os.path.getsize(dds) // (1024 * 1024)} MB) + preview")
    if QUAD:
        build_home_quad(os.path.join(assets, "Models"))
    print("done. Models/ortho_home.* (runtime-placed quad) is the reliable path; "
          "the Orthophotos/ .dds tiles are the optional FG_PHOTOSCENERY=true path.")


if __name__ == "__main__":
    main()
