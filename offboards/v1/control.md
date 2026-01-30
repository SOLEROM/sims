# how control works

* In a real drone, you send velocity setpoints to the FCU via MAVLink, and the FCU handles converting that to motor commands while respecting physical limits.

```
┌────────────┐     ┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│ Controller │────▶│ FCU Filter  │────▶│  Kinematics │────▶│ New Position │
│            │     │             │     │  (integrate)│     │              │
│ outputs:   │     │ smooths &   │     │ v → Δpos    │     │ x, y, yaw    │
│ v_fwd      │     │ limits      │     │             │     │              │
│ v_lat      │     │ velocity    │     │             │     │              │
│ yaw_rate   │     │             │     │             │     │              │
└────────────┘     └─────────────┘     └─────────────┘     └──────────────┘

```
## (1) Controller command

```
# Controller says "I want to go forward at 1.2 m/s and turn at 0.5 rad/s"
CmdVel(v_fwd=1.2, v_lat=0.0, yaw_rate=0.5)
```

## (2) FCU Filter smooth
* FCU limits acceleration and max velocity to make motion realistic

```
# In FCUSetpointFilter.step():
# If controller suddenly wants v=2.0 but drone is at v=0,
# FCU only allows v to increase by (a_max * dt) per step
dv = self.a_max * dt  # e.g., 2.5 m/s² × 0.005s = 0.0125 m/s per step
self._v_fwd += clip(desired - current, -dv, dv)

```

## (3) Kinematics integrate

* velocity → position (integration)

```
# Convert body velocity to world velocity
vx_world, vy_world = body_to_world(fcu_cmd.v_fwd, fcu_cmd.v_lat, drone.yaw)

# Integrate: position += velocity × time
drone.x += vx_world * dt
drone.y += vy_world * dt
drone.yaw += fcu_cmd.yaw_rate * dt
```