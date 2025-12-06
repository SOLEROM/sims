# run core 16 + gazebo

build :
```
docker build -f Dockerfile.px4-sitl-gazebo -t px4-sitl-16 .

```

run: 

```
mkdir -p logs
xhost +local:docker

docker run --rm -it \
  --name px4-sitl-16 \
  --net=host \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$PWD/logs:/root/Firmware/build/px4_sitl_default/logs" \
  px4-sitl-16

```


## if over ssh

```
ssh -Y ... // do -Y to connect to the run machine
then on that station:

> export XAUTHORITY="$HOME/.Xauthority"

echo $DISPLAY
# should be something like: localhost:10.0
echo $XAUTHORITY
# might be empty or something like /home/user/.Xauthority




```

## sim mode manual


* first shell:

```
export XAUTHORITY=$HOME/.Xauthority

docker run --rm -it \
  --name px4-sitl-16 \
  --net=host \
  -e DISPLAY=$DISPLAY \
  -e XAUTHORITY=/root/.Xauthority \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$XAUTHORITY:/root/.Xauthority:ro" \
  -v "$PWD/logs:/root/PX4-Autopilot/build/px4_sitl_default/logs" \
  px4-sitl-16



cd /root/PX4-Autopilot
./run_gz_hitl_iris.sh
```

* second shell :

```
docker exec -it px4-sitl-16 bash

cd /root/PX4-Autopilot/build/px4_sitl_default/rootfs
./runFull.sh
```

## sim mode auto

* use run script 
  * will set XAUTHORITY
  * for first run wil spin the docker
  * for second run will enter with bash
  * run > runGzPX4