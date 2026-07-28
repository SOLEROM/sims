# flightgear

* https://www.flightgear.org/

## versions

| dir | base | flightgear | capabilities |
|-----|------|-----------|--------------|
| `craft_base_20` | ubuntu 20.04 | 2019.1.1 (distro) | legacy: standalone runner only |
| `craft_base_24` | ubuntu 24.04 | saiarcot895 PPA | **current**: standalone + external-fdm (drone-camera renderer), multi-instance via `ID`, netns-join, FGFS_GPU backend select, ortho satellite ground toolkit, headless validation |

New projects: start from `craft_base_24` (see its `readme.md`). `craft_base_20`
is kept as the frozen reference of the original minimal layer.

## tree structure

```
├─ craft_base_20/            # frozen legacy base (build.sh / run.sh)
├─ craft_base_24/            # current generic base + tools (see its readme)
│    Dockerfile.base         # generic FlightGear image
│    run.sh / fgfs_runner.sh # host runner / in-container dual-mode launcher
│    tools/                  # tile math, ortho + objects generators, validation
├─ craft_PLATFORMX/          # (pattern) project overlay: FROM fgfs-base:24
│                            #  + COPY scenery/aircraft/protocol — or use
│                            #  runtime FG_ASSETS_DIR mounts instead
```

* build: `<path>/build.sh`
* run:   `<path>/run.sh`
* validate (24): `<path>/tools/validate.sh --all`
