#!/usr/bin/env python3
"""fg_tiles.py — FlightGear scenery tile (SGBucket) math. stdlib only.

Faithful port of simgear/bucket/newbucket.{hxx,cxx}: bucket span table, bucket
selection, tile index packing, bbox, and the on-disk directory naming
(<10x10>/<1x1>, e.g. e030n30/e035n32). This replaces the ad-hoc span table that
shipped in an earlier gen-orthophotos.py, which returned 0.125 for lat>=22 (real
value: 0.25) — it happened not to bite there only because the home longitude
fell in bucket column x=0 either way.

Library:
    tile_index(lon, lat) -> int
    tile_bbox(index)     -> (lon0, lat0, lon1, lat1)
    tile_dirs(lon, lat)  -> ("e030n30", "e035n32")
    stg_relpath(lon, lat) -> "e030n30/e035n32/3530424.stg"

CLI:
    fg_tiles.py LAT LON        # print index + bucket path for a point
    fg_tiles.py --selftest     # verify against known-good tiles
"""
import math
import sys


def bucket_span(lat):
    """Bucket width in degrees of longitude at latitude `lat` (signed, like
    simgear sg_bucket_span — the table is symmetric but keyed on signed lat)."""
    if lat >= 89.0:
        return 360.0
    if lat >= 88.0:
        return 8.0
    if lat >= 86.0:
        return 4.0
    if lat >= 83.0:
        return 2.0
    if lat >= 76.0:
        return 1.0
    if lat >= 62.0:
        return 0.5
    if lat >= 22.0:
        return 0.25
    if lat >= -22.0:
        return 0.125
    if lat >= -62.0:
        return 0.25
    if lat >= -76.0:
        return 0.5
    if lat >= -83.0:
        return 1.0
    if lat >= -86.0:
        return 2.0
    if lat >= -88.0:
        return 4.0
    return 8.0


def _bucket(lon, lat):
    """simgear SGBucket::set_bucket -> (lon_cell, lat_cell, x, y)."""
    lon_floor = math.floor(lon)
    lat_floor = math.floor(lat)
    lat_cell = int(lat_floor)
    y = int((lat - lat_floor) * 8)
    span = bucket_span(lat)
    if span < 0.0000001:
        lon_cell = int(lon_floor)
        x = 0
    elif span <= 1.0:
        lon_cell = int(lon_floor)
        x = int((lon - lon_floor) / span)
    else:
        # wide high-latitude buckets snap the cell to a span-aligned boundary
        if lon >= 0:
            lon_cell = int(int(lon_floor / span) * span)
        else:
            lon_cell = int(int((lon_floor + 1) / span) * span - span)
        x = 0
    return lon_cell, lat_cell, x, y


def tile_index(lon, lat):
    """FlightGear tile index (the .stg basename) for a lon/lat point."""
    lon_cell, lat_cell, x, y = _bucket(lon, lat)
    return ((lon_cell + 180) << 14) + ((lat_cell + 90) << 6) + (y << 3) + x


def tile_bbox(index):
    """(lon0, lat0, lon1, lat1) geographic bounds of a tile index."""
    x = index & 0x7
    y = (index >> 3) & 0x7
    lat_cell = ((index >> 6) & 0xFF) - 90
    lon_cell = ((index >> 14) & 0x3FF) - 180
    span = bucket_span(lat_cell + y * 0.125 + 0.0625)  # bucket CENTER lat, like SGBucket::get_width
    lon0 = lon_cell + x * span
    lat0 = lat_cell + y * 0.125
    return lon0, lat0, lon0 + span, lat0 + 0.125


def tile_dirs(lon, lat):
    """FG directory pair: 10x10 chunk and 1x1 cell, e.g. ("e030n30", "e035n32")."""
    lon10 = int(math.floor(lon / 10.0) * 10)
    lat10 = int(math.floor(lat / 10.0) * 10)
    lon1 = int(math.floor(lon))
    lat1 = int(math.floor(lat))

    def ew(v):
        return ("e%03d" % v) if v >= 0 else ("w%03d" % -v)

    def ns(v):
        return ("n%02d" % v) if v >= 0 else ("s%02d" % -v)

    return "%s%s" % (ew(lon10), ns(lat10)), "%s%s" % (ew(lon1), ns(lat1))


def stg_relpath(lon, lat):
    """Relative Objects/ path of the .stg covering a point."""
    d10, d1 = tile_dirs(lon, lat)
    return "%s/%s/%d.stg" % (d10, d1, tile_index(lon, lat))


def selftest():
    """Known-good tiles: the reference home site (verified live scenery) + KSFO (the classic
    FG example whose .stg name is public knowledge)."""
    cases = [
        # lat, lon, index, d10, d1
        (32.941770, 35.100300, 3530424, "e030n30", "e035n32"),  # reference home site
        (37.613544, -122.357172, 942050, "w130n30", "w123n37"),  # KSFO
    ]
    for lat, lon, want_idx, want_d10, want_d1 in cases:
        idx = tile_index(lon, lat)
        d10, d1 = tile_dirs(lon, lat)
        assert idx == want_idx, "index(%s,%s)=%d want %d" % (lat, lon, idx, want_idx)
        assert (d10, d1) == (want_d10, want_d1), "dirs(%s,%s)=%s/%s want %s/%s" % (
            lat, lon, d10, d1, want_d10, want_d1)
        lon0, lat0, lon1, lat1 = tile_bbox(idx)
        assert lon0 <= lon < lon1 and lat0 <= lat < lat1, \
            "bbox of %d does not contain %s,%s" % (idx, lat, lon)
    # span sanity at the band the old table got wrong
    assert bucket_span(32.9) == 0.25, "span at lat 32.9 must be 0.25"
    assert bucket_span(10.0) == 0.125
    assert bucket_span(-32.9) == 0.25
    print("fg_tiles selftest OK (%d known tiles + span table)" % len(cases))


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        selftest()
        return 0
    if len(argv) != 3:
        print(__doc__)
        return 2
    lat, lon = float(argv[1]), float(argv[2])
    idx = tile_index(lon, lat)
    print("index: %d" % idx)
    print("stg:   Objects/%s" % stg_relpath(lon, lat))
    print("bbox:  lon[%.5f, %.5f] lat[%.5f, %.5f]" % tile_bbox(idx))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
