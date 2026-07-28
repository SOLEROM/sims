# addobj.nas — generic runtime "add object" hook + ortho-ground auto-place
# (craft_base_24; generalized from the reference sim's addobj.nas).
#
# FlightGear auto-loads every $FG_ROOT/Nasal/*.nas at startup; this file is
# baked into the base image (a project can override it via a bind-mount).
#
# 1) RUNTIME OBJECT PLACEMENT. The props/telnet protocol cannot run Nasal
#    directly, so this property->command bridge is the standard pattern. An
#    external tool drops a model into the live scene WITHOUT restarting FG:
#
#      set /addobj/{path,lat,lon,elev-m,hdg-deg,pitch-deg,roll-deg}
#      bump /addobj/seq            -> this listener fires -> geo.put_model(...)
#
#    elev-m is meters AMSL; nil/-9999 => follow terrain.
#
# 2) ORTHO SATELLITE-GROUND AUTO-PLACE at startup, from /ortho/* props (fed by
#    fgfs_runner.sh). Two behaviors proven live on this FG build:
#      - STATIC .stg placement of the ground quad LOADS but never RENDERS (it
#        loses to the terrain); the IDENTICAL model placed at runtime via
#        geo.put_model renders fine. Hence this hook.
#      - A flat plane is only visible from ABOVE it, so its elevation must sit
#        just below the (landed) camera and just above local terrain. Explicit
#        /ortho/elev-m wins; unset/-9999 => terrain + /ortho/elev-offset-m.
#        Do NOT trust geo.elevation() early in the load for the explicit path —
#        it returns coarse/wrong values and re-buries the plane.

var ROOT = "/addobj";

setprop(ROOT ~ "/seq", 0);
setprop(ROOT ~ "/count", 0);

var place = func {
    var path = getprop(ROOT ~ "/path");
    var lat  = getprop(ROOT ~ "/lat");
    var lon  = getprop(ROOT ~ "/lon");
    var elev = getprop(ROOT ~ "/elev-m");
    var hdg  = getprop(ROOT ~ "/hdg-deg");
    var pit  = getprop(ROOT ~ "/pitch-deg");
    var rol  = getprop(ROOT ~ "/roll-deg");
    if (path == nil or lat == nil or lon == nil) {
        print("addobj: missing path/lat/lon, ignoring");
        return;
    }
    if (elev != nil and elev <= -9000) elev = nil;   # sentinel => terrain-follow
    if (hdg == nil) hdg = 0;
    if (pit == nil) pit = 0;
    if (rol == nil) rol = 0;
    var err = call(func { geo.put_model(path, lat, lon, elev, hdg, pit, rol); }, nil, var e = []);
    if (size(e)) {
        print("addobj: put_model FAILED: ", e[0]);
        return;
    }
    setprop(ROOT ~ "/count", getprop(ROOT ~ "/count") + 1);
    print(sprintf("addobj: placed %s @ %.6f,%.6f elev=%s hdg=%.1f (#%d)",
                  path, lat, lon, (elev == nil ? "ground" : sprintf("%.1f", elev)),
                  hdg, getprop(ROOT ~ "/count")));
};

# fire whenever seq changes (startup value ignored via init flag 0)
setlistener(ROOT ~ "/seq", func { place(); }, 0, 0);
print("addobj.nas loaded; listening on ", ROOT, "/seq");

# ---------------------------------------------------------------------------
# ortho satellite-ground auto-place (props under /ortho, set by fgfs_runner.sh)
# ---------------------------------------------------------------------------
var auto_place_ortho = func {
    if (getprop("/ortho/auto") != 1) return;
    var path = getprop("/ortho/path");
    var lat  = getprop("/ortho/lat");
    var lon  = getprop("/ortho/lon");
    if (path == nil or lat == nil or lon == nil) {
        print("addobj: ortho auto-place skipped (no path/lat/lon)");
        return;
    }
    var elev = getprop("/ortho/elev-m");              # explicit AMSL (optional)
    var off  = getprop("/ortho/elev-offset-m");
    if (off == nil) off = 1.5;
    if (elev == nil or elev < -9000) {                # auto: terrain + offset
        var g = geo.elevation(lat, lon);              # AMSL terrain at the point
        elev = (g != nil) ? g + off : 3.0;            # fallback if terrain not ready
    }
    var err = call(func { geo.put_model(path, lat, lon, elev, 0, 0, 0); }, nil, var e = []);
    if (size(e)) { print("addobj: ortho auto-place FAILED: ", e[0]); return; }
    setprop("/ortho/placed-elev-m", elev);
    print(sprintf("addobj: ortho ground auto-placed @ %.6f,%.6f elev=%.2f (runtime)",
                  lat, lon, elev));
};

# place once the scenery is loaded (terrain elevation must be ready); retry for
# a while, then give up — auto-place is best-effort, the /addobj hook above
# still works manually.
var _ortho_tries = 0;
var ortho_boot = func {
    _ortho_tries += 1;
    if (getprop("/sim/sceneryloaded") == 1 or _ortho_tries > 40) {
        auto_place_ortho();
    } else {
        settimer(ortho_boot, 1.0);
    }
};
settimer(ortho_boot, 2.0);
