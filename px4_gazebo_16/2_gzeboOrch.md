# connection to px4

## Side-by-side mental picture

### seperate process

* You ran PX4: `./runFull.sh`
* You ran Gazebo separately: `./run_gz_hitl_iris.sh`
* Two independent processes, you coordinate them.

### one process

* You run only: `./runGzPX4.sh`
* PX4 (via `rcS`) decides:

```
because PX4_SIM_MODEL is a gz_* model, PX4’s init logic does:

INFO  [init] Gazebo simulator
INFO  [init] Starting gazebo with world: .../default.sdf
INFO  [init] Starting gz gui
```

  * “I’m a GZ sim, so I’ll spawn `gz sim` + GUI myself.”
* One command, PX4 + gz launched and wired automatically.

---

So the short explanation:

> **Previously** you started Gazebo manually as a separate app.
> **Now** PX4’s startup script detects “Gazebo simulator” and **auto-spawns `gz sim` + GUI**, so a single `runGzPX4.sh` is enough to bring up both PX4 and Gazebo together.
