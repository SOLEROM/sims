"""
Core simulation engine for drone target tracking.

This module provides:
- SimConfig: Configuration dataclass for simulation parameters
- Simulator: Main simulation class with run() and plot() methods
- Helper functions for perception modeling
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable
import numpy as np

from .models import (
    DroneState,
    TargetState,
    Perception,
    CmdVel,
    FCUSetpointFilter,
    body_to_world,
    wrap_pi,
)
from .controllers import ControllerBase, make_controller
from .scenarios import get_target
from .metrics import summarize, SimulationMetrics


@dataclass
class SimConfig:
    """
    Configuration for a simulation run.
    
    All parameters have sensible defaults. Customize what you need.
    """
    
    # Timing
    duration: float = 40.0       # Total simulation time (seconds)
    sim_hz: float = 200.0        # Physics simulation rate (Hz)
    ctrl_hz: float = 30.0        # Controller update rate (Hz)
    
    # Initial conditions
    drone_x0: float = -2.0
    drone_y0: float = -2.0
    drone_yaw0_deg: float = 45.0
    target_x0: float = 6.0
    target_y0: float = 0.0
    
    # Perception noise (set to 0 for perfect sensing)
    noise_bearing: float = 0.02  # Bearing noise std dev (rad)
    noise_range: float = 0.05    # Range noise std dev (m)
    
    # FCU limits (what the flight controller enforces)
    v_max: float = 2.0           # Max velocity (m/s)
    a_max: float = 2.5           # Max acceleration (m/s²)
    yaw_rate_max: float = 1.5    # Max yaw rate (rad/s)
    
    # Metrics
    capture_radius: float = 0.7  # Distance considered "captured"
    
    # Reproducibility
    seed: int = 1
    
    @property
    def dt(self) -> float:
        """Physics timestep."""
        return 1.0 / self.sim_hz
    
    @property
    def ctrl_dt(self) -> float:
        """Controller timestep."""
        return 1.0 / self.ctrl_hz


def perception_model(
    drone: DroneState,
    target: TargetState,
    noise_bearing: float = 0.0,
    noise_range: float = 0.0,
) -> Perception:
    """
    Simulate perception (what the drone "sees").
    
    Computes bearing and range to target, optionally adding noise.
    
    Args:
        drone: Current drone state
        target: Current target state
        noise_bearing: Bearing noise std dev (rad)
        noise_range: Range noise std dev (m)
        
    Returns:
        Perception with bearing error (in body frame) and range
    """
    # Vector to target in world frame
    dx = target.x - drone.x
    dy = target.y - drone.y
    range_m = float(np.hypot(dx, dy))
    
    # Bearing in world frame, then convert to body frame
    bearing_world = np.arctan2(dy, dx)
    bearing_err = wrap_pi(float(bearing_world - drone.yaw))
    
    # Add noise
    if noise_bearing > 0:
        bearing_err += float(np.random.normal(0.0, noise_bearing))
        bearing_err = wrap_pi(bearing_err)
    if noise_range > 0:
        range_m = float(max(0.0, range_m + np.random.normal(0.0, noise_range)))
    
    return Perception(bearing_err=bearing_err, range_m=range_m, valid=True)


@dataclass
class SimulationResult:
    """Container for simulation results."""
    
    # Time series data
    t: np.ndarray              # Time stamps
    drone: np.ndarray          # Drone states (N x 3: x, y, yaw)
    target: np.ndarray         # Target positions (N x 2: x, y)
    dist: np.ndarray           # Distance to target
    cmd_v: np.ndarray          # Commanded velocity magnitude
    cmd_yaw: np.ndarray        # Commanded yaw rate
    
    # Configuration used
    config: SimConfig = None
    controller_name: str = ""
    scenario_name: str = ""
    scenario_kwargs: dict = None  # Scenario parameters used
    
    # Computed metrics
    metrics: SimulationMetrics = None
    
    def to_dict(self) -> dict:
        """Convert to dictionary format (compatible with metrics.summarize)."""
        return {
            "t": self.t,
            "dist": self.dist,
            "cmd_v": self.cmd_v,
            "cmd_yaw": self.cmd_yaw,
            "capture_radius": self.config.capture_radius if self.config else 0.7,
            "drone": self.drone,
            "target": self.target,
        }


class Simulator:
    """
    Main simulation class.
    
    Usage:
        sim = Simulator()
        result = sim.run(controller="pidyaw", scenario="circle")
        sim.plot(result)
        print(result.metrics)
    """
    
    def __init__(self, config: SimConfig = None):
        """
        Initialize simulator.
        
        Args:
            config: Simulation configuration (uses defaults if None)
        """
        self.config = config or SimConfig()
    
    def run(
        self,
        controller: str | ControllerBase = "p",
        scenario: str = "circle",
        config: SimConfig = None,
        scenario_kwargs: dict = None,
        **controller_kwargs,
    ) -> SimulationResult:
        """
        Run a simulation.
        
        Args:
            controller: Controller name ("p", "pidyaw", "pursuit") or instance
            scenario: Scenario name ("circle", "line", "random", etc.)
            config: Override config for this run
            scenario_kwargs: Override scenario parameters, e.g.:
                - circle: {"radius": 8.0, "omega": 0.2, "center": (0, 0)}
                - line: {"speed": 1.0, "start": (5, 0), "oscillation": 3.0, "osc_freq": 0.5}
                - figure_eight: {"scale": 6.0, "omega": 0.2, "center": (0, 0)}
                - stationary: {"position": (10, 5)}
                - random: {"step": 0.8}
            **controller_kwargs: Override controller parameters
            
        Returns:
            SimulationResult with all data and metrics
            
        Examples:
            # Custom line scenario
            result = sim.run(
                controller="p",
                scenario="line",
                scenario_kwargs={"speed": 1.2, "oscillation": 3.0}
            )
            
            # Custom circle with custom controller gains
            result = sim.run(
                controller="pidyaw",
                scenario="circle",
                scenario_kwargs={"radius": 10.0, "omega": 0.1},
                k_p=2.5, k_i=0.3
            )
        """
        cfg = config or self.config
        scenario_kwargs = scenario_kwargs or {}
        
        # Setup
        dt = cfg.dt
        ctrl_dt = cfg.ctrl_dt
        steps = int(cfg.duration / dt)
        
        # Create controller
        if isinstance(controller, str):
            ctrl = make_controller(controller, **controller_kwargs)
            controller_name = controller
        else:
            ctrl = controller
            controller_name = getattr(ctrl, "name", "custom")
        ctrl.reset()
        
        # Initialize states
        drone = DroneState(
            x=cfg.drone_x0,
            y=cfg.drone_y0,
            yaw=np.deg2rad(cfg.drone_yaw0_deg),
        )
        target = TargetState(x=cfg.target_x0, y=cfg.target_y0)
        
        # FCU filter
        fcu = FCUSetpointFilter(
            v_max=cfg.v_max,
            a_max=cfg.a_max,
            yaw_rate_max=cfg.yaw_rate_max,
        )
        
        # Timing
        t = 0.0
        next_ctrl_t = 0.0
        last_cmd = CmdVel(0.0, 0.0, 0.0)
        
        # Allocate log arrays
        log_t = np.zeros(steps)
        log_dist = np.zeros(steps)
        log_cmd_v = np.zeros(steps)
        log_cmd_yaw = np.zeros(steps)
        log_drone = np.zeros((steps, 3))
        log_target = np.zeros((steps, 2))
        
        # Set random seed
        np.random.seed(cfg.seed)
        
        # Create scenario config with kwargs
        from .scenarios import ScenarioConfig
        scenario_cfg = ScenarioConfig(name=scenario, kwargs=scenario_kwargs)
        
        # Main loop
        for k in range(steps):
            # Update target
            target = get_target(scenario_cfg, t, target, dt, seed=cfg.seed)
            
            # Controller update at ctrl_hz
            if t >= next_ctrl_t - 1e-9:
                p = perception_model(drone, target, cfg.noise_bearing, cfg.noise_range)
                last_cmd = ctrl.step(p, ctrl_dt)
                next_ctrl_t += ctrl_dt
            
            # FCU filter
            fcu_cmd = fcu.step(last_cmd, dt)
            
            # Integrate drone kinematics
            vx_w, vy_w = body_to_world(fcu_cmd.v_fwd, fcu_cmd.v_lat, drone.yaw)
            drone.vx = vx_w
            drone.vy = vy_w
            drone.x += drone.vx * dt
            drone.y += drone.vy * dt
            drone.yaw = wrap_pi(drone.yaw + fcu_cmd.yaw_rate * dt)
            
            # Log
            dx = target.x - drone.x
            dy = target.y - drone.y
            dist = float(np.hypot(dx, dy))
            
            log_t[k] = t
            log_dist[k] = dist
            log_cmd_v[k] = float(np.hypot(fcu_cmd.v_fwd, fcu_cmd.v_lat))
            log_cmd_yaw[k] = fcu_cmd.yaw_rate
            log_drone[k] = [drone.x, drone.y, drone.yaw]
            log_target[k] = [target.x, target.y]
            
            t += dt
        
        # Create result
        result = SimulationResult(
            t=log_t,
            drone=log_drone,
            target=log_target,
            dist=log_dist,
            cmd_v=log_cmd_v,
            cmd_yaw=log_cmd_yaw,
            config=cfg,
            controller_name=controller_name,
            scenario_name=scenario,
            scenario_kwargs=scenario_kwargs,
        )
        
        # Compute metrics
        result.metrics = summarize(result.to_dict())
        
        return result
    
    def plot(
        self,
        result: SimulationResult,
        figsize: tuple[int, int] = (12, 8),
        show: bool = True,
    ):
        """
        Plot simulation results.
        
        Args:
            result: SimulationResult from run()
            figsize: Figure size
            show: Whether to call plt.show()
        """
        import matplotlib.pyplot as plt
        
        fig, axes = plt.subplots(2, 2, figsize=figsize)
        fig.suptitle(
            f"Controller: {result.controller_name.upper()} | "
            f"Scenario: {result.scenario_name}",
            fontsize=12,
        )
        
        t = result.t
        drone = result.drone
        target = result.target
        capture_r = result.config.capture_radius if result.config else 0.7
        
        # XY Path
        ax = axes[0, 0]
        ax.plot(target[:, 0], target[:, 1], "r-", label="Target", alpha=0.7)
        ax.plot(drone[:, 0], drone[:, 1], "b-", label="Drone", alpha=0.7)
        ax.plot(drone[0, 0], drone[0, 1], "bo", markersize=8, label="Start")
        ax.plot(drone[-1, 0], drone[-1, 1], "bs", markersize=8, label="End")
        ax.set_xlabel("X (m)")
        ax.set_ylabel("Y (m)")
        ax.set_title("XY Path")
        ax.axis("equal")
        ax.legend()
        ax.grid(True, alpha=0.3)
        
        # Distance over time
        ax = axes[0, 1]
        ax.plot(t, result.dist, "b-")
        ax.axhline(capture_r, color="g", linestyle="--", label=f"Capture ({capture_r}m)")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Distance (m)")
        ax.set_title("Tracking Distance")
        ax.legend()
        ax.grid(True, alpha=0.3)
        
        # Velocity command
        ax = axes[1, 0]
        ax.plot(t, result.cmd_v, "b-")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Velocity (m/s)")
        ax.set_title("Velocity Command Magnitude")
        ax.grid(True, alpha=0.3)
        
        # Yaw rate command
        ax = axes[1, 1]
        ax.plot(t, result.cmd_yaw, "b-")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Yaw Rate (rad/s)")
        ax.set_title("Yaw Rate Command")
        ax.grid(True, alpha=0.3)
        
        plt.tight_layout()
        
        if show:
            plt.show()
        
        return fig, axes
