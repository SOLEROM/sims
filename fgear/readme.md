# flightgear

* https://www.flightgear.org/


## versions

craft_base_20:
* ubu=20 ; fgear=2019.1.1

##  tree structure

```
├─ Dockerfile.fgfs.base        # Generic FlightGear
├─ Dockerfile.fgfs.PLATFORMX   # FlightGear +  custom scenery/aircraft/etc
├─ build-fgfs.sh               # Build wrapper
├─ craft_base/                 # folder for base build
├─ craft_PLATFORMX/            # based on base

```

* build : ``` > <path>/build.sh```
* run:  ``` > <path>/run.sh```

