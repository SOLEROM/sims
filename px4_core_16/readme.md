# run core 11 only

build :
```
docker build -f Dockerfile.px4-sitl-core -t px4-sitl-16 .

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
