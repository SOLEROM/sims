# 🚁 Drone Target Tracking Simulator

A perception-based target tracking simulator for drones. Perfect for learning about control systems, experimenting with different algorithms, and understanding drone dynamics.

## What It Simulates

```
┌──────────────┐     ┌────────────┐     ┌─────────────┐     ┌───────────┐
│   Target     │────▶│ Perception │────▶│ Controller  │────▶│   Drone   │
│  (moving)    │     │ (bearing,  │     │ (P, PID,    │     │ (position,│
│              │     │  range)    │     │  Pursuit)   │     │  heading) │
└──────────────┘     └────────────┘     └─────────────┘     └───────────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │ FCU Filter  │
                                        │ (vel/accel  │
                                        │  limits)    │
                                        └─────────────┘
```

- **World (2D)**: Drone with position, heading, and velocity; moving target
- **Perception**: Simulated sensor that returns bearing and range (with optional noise)
- **Controllers**: P, PID, Pure Pursuit-style algorithms
- **FCU Filter**: Simulates flight controller smoothing and limits
- **Metrics**: RMS tracking error, time-to-capture, control energy

## 🚀 Quick Start

### 1. Create a Virtual Environment

```bash
# Create and activate virtual environment
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install the package in development mode
pip install -e .
```

### 2. Run the Interactive Notebook (Recommended)

```bash
jupyter notebook notebooks/01_getting_started.ipynb
```

### 3. Or Use the Command Line

```bash
# Basic run with plots
drone-sim --controller PIDYaw --scenario circle --plot

# Compare controllers
drone-sim --controller P --scenario circle
drone-sim --controller PIDYaw --scenario circle
drone-sim --controller Pursuit --scenario circle

# Add noise
drone-sim --controller PIDYaw --scenario circle --noise-bearing 0.1 --plot
```

### 4. Or Use as a Library

```python
from drone_tracker import Simulator, SimConfig

# Create simulator
sim = Simulator()

# Run simulation
result = sim.run(controller="pidyaw", scenario="circle")

# View metrics
print(result.metrics)

# Plot results
sim.plot(result)
```

## 📁 Project Structure

```
drone_tracker/
├── pyproject.toml           # Modern Python packaging
├── README.md
│
├── src/drone_tracker/       # Main package
│   ├── __init__.py          # Clean public API
│   ├── models.py            # Data structures (DroneState, CmdVel, etc.)
│   ├── controllers.py       # Control algorithms
│   ├── scenarios.py         # Target motion patterns
│   ├── metrics.py           # Performance measurement
│   ├── simulator.py         # Core simulation engine
│   └── cli.py               # Command-line interface
│
└── notebooks/
    └── 01_getting_started.ipynb  # Interactive tutorial
```

## 🎮 Controllers

| Controller | Description | Pros | Cons |
|------------|-------------|------|------|
| **P** | Proportional control | Simple, fast | Can oscillate |
| **PIDYaw** | PID on yaw, P on velocity | Smooth, handles noise | Slower to respond |
| **Pursuit** | Pure pursuit-style | Good convergence | May be slower initially |

## 🎯 Scenarios

| Scenario | Description |
|----------|-------------|
| `circle` | Target moves in a circle (good for tracking tests) |
| `line` | Linear motion with sine wave oscillation |
| `figure_eight` | Figure-8 pattern for complex tracking |
| `stationary` | Static target (convergence testing) |
| `random` | Random walk (robustness testing) |

## 📊 Key Metrics

- **RMS Distance**: Average tracking error (lower = better)
- **Min Distance**: Closest approach achieved
- **Time to Capture**: Time to reach within capture radius
- **Control Energy**: Sum of squared commands (lower = smoother)

## 🔧 Configuration Options

```python
from drone_tracker import SimConfig

config = SimConfig(
    # Timing
    duration=40.0,        # Simulation length (seconds)
    sim_hz=200.0,         # Physics rate (Hz)
    ctrl_hz=30.0,         # Controller rate (Hz)
    
    # Initial conditions
    drone_x0=-2.0,
    drone_y0=-2.0,
    drone_yaw0_deg=45.0,
    
    # Sensor noise
    noise_bearing=0.02,   # Bearing noise (rad std dev)
    noise_range=0.05,     # Range noise (m std dev)
    
    # FCU limits
    v_max=2.0,            # Max velocity (m/s)
    a_max=2.5,            # Max acceleration (m/s²)
    yaw_rate_max=1.5,     # Max yaw rate (rad/s)
    
    # Metrics
    capture_radius=0.7,   # "Captured" threshold (m)
)
```

## 🎓 Learning Path

1. **Start with the notebook** - Run `01_getting_started.ipynb` and go through each section
2. **Compare controllers** - See how P, PID, and Pursuit differ
3. **Add noise** - See how controllers handle sensor uncertainty
4. **Tune parameters** - Try different gains and see the effects
5. **Create your own controller** - Inherit from `ControllerBase` and experiment!

## 💡 Tips for Experimentation

### Tuning P Controller
- `k_yaw`: Higher = faster turning, but can overshoot
- `k_fwd`: Higher = faster approach, but can cause overshoot
- `slow_if_offcenter`: Prevents orbiting behavior

### Tuning PID Controller
- Start with `k_i=0` and tune `k_p` first
- Add small `k_i` to eliminate steady-state error
- Use `k_d` to reduce oscillation

### Testing Robustness
- Increase noise gradually to see when tracking degrades
- Try different scenarios to find controller weaknesses
- Reduce `ctrl_hz` to simulate slower processing
