
For SITL / Gazebo dev, the standard workaround (also used in px4_ros_com) is to turn off the RC/GCS loss actions so they don’t participate in the preflight check. 


pxh> param set NAV_RCL_ACT 0
pxh> param set NAV_DLL_ACT 0
pxh> param save
pxh> commander check

pxh> commander arm
pxh> commander takeoff


## how to update my params file

* inside the running docker it is:

/root/PX4-Autopilot/build/px4_sitl_default/rootfs/parameters.bson

* run px4 control shell and set my defaults:
```
pxh> param set NAV_RCL_ACT 0
pxh> param set NAV_DLL_ACT 0
pxh> param save
pxh> shutdown

```

* then on host cp the confs to be usend in docker build:
```
docker cp px4-sitl-16:/root/PX4-Autopilot/build/px4_sitl_default/rootfs/parameters.bson  parameters.bson
Successfully copied 2.05kB to /home/user/proj/sims/dockersBuild/px4_gazebo_16/parameters
```


