"""
Control algorithms for drone target tracking.

Each controller takes perception input (bearing/range to target) and
outputs velocity commands. Different controllers have different characteristics:

- PController: Simple proportional control, fast but can oscillate
- PIDYawController: Adds integral/derivative for smoother yaw tracking
- PurePursuitLike: Geometric approach inspired by pursuit guidance

All controllers inherit from ControllerBase and implement:
- reset(): Clear internal state
- step(perception, dt) -> CmdVel: Compute next command
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
import numpy as np

from .models import CmdVel, Perception, wrap_pi


class ControllerBase(ABC):
    """Abstract base class for all controllers."""
    
    name: str = "base"
    
    def reset(self) -> None:
        """Reset controller internal state (called at start of simulation)."""
        pass
    
    @abstractmethod
    def step(self, perception: Perception, dt: float) -> CmdVel:
        """
        Compute velocity command based on current perception.
        
        Args:
            perception: Current sensor reading (bearing, range, validity)
            dt: Time since last call (seconds)
            
        Returns:
            Velocity command to send to FCU
        """
        raise NotImplementedError


@dataclass
class PController(ControllerBase):
    """
    Simple Proportional controller.
    
    Strategy:
    - Yaw rate proportional to bearing error (turn toward target)
    - Forward speed proportional to range (faster when far)
    - Optional: slow down when target is off-center
    
    Pros: Simple, responsive
    Cons: Can oscillate, no steady-state error correction
    
    Tuning tips:
    - k_yaw: Higher = faster turning, but can overshoot
    - k_fwd: Higher = faster approach, but can overshoot
    - slow_if_offcenter: Helps prevent orbiting behavior
    """
    
    name: str = "P"
    
    # Gains
    k_yaw: float = 1.8      # yaw_rate = k_yaw * bearing_error
    k_fwd: float = 0.6      # v_fwd = k_fwd * range
    k_lat: float = 0.0      # v_lat = k_lat * bearing_error (usually 0)
    
    # Limits
    v_fwd_max: float = 1.5
    v_lat_max: float = 1.0
    yaw_rate_max: float = 1.2
    
    # Behavior
    slow_if_offcenter: bool = True
    
    def step(self, p: Perception, dt: float) -> CmdVel:
        if not p.valid:
            return CmdVel(0.0, 0.0, 0.0)
        
        bearing = wrap_pi(p.bearing_err)
        
        # Yaw control: turn toward target
        yaw_rate = np.clip(self.k_yaw * bearing, -self.yaw_rate_max, self.yaw_rate_max)
        
        # Forward velocity: approach target
        v_fwd = np.clip(self.k_fwd * p.range_m, 0.0, self.v_fwd_max)
        
        # Slow down if target is far off-center (prevents orbiting)
        if self.slow_if_offcenter:
            if abs(bearing) < np.pi / 2:
                v_fwd *= float(np.cos(bearing))
            else:
                v_fwd = 0.0
        
        # Lateral velocity (optional)
        v_lat = np.clip(self.k_lat * bearing, -self.v_lat_max, self.v_lat_max)
        
        return CmdVel(float(v_fwd), float(v_lat), float(yaw_rate))


@dataclass
class PIDYawController(ControllerBase):
    """
    PID controller for yaw with P control for forward velocity.
    
    Strategy:
    - PID control on yaw to eliminate steady-state bearing error
    - P control on forward velocity (same as PController)
    
    Pros: Better tracking under noise, eliminates steady-state error
    Cons: More complex to tune, can be slower to respond
    
    Tuning tips:
    - k_p: Proportional gain, main responsiveness
    - k_i: Integral gain, eliminates steady-state error (start small!)
    - k_d: Derivative gain, dampens oscillations
    - Anti-windup: Integral is clamped to [-1, 1] to prevent windup
    """
    
    name: str = "PIDYaw"
    
    # PID gains for yaw
    k_p: float = 2.0
    k_i: float = 0.4
    k_d: float = 0.12
    
    # Forward velocity gain
    k_fwd: float = 0.7
    
    # Limits
    v_fwd_max: float = 1.6
    yaw_rate_max: float = 1.4
    
    # Internal state
    _integral: float = field(default=0.0, repr=False)
    _prev_error: float = field(default=0.0, repr=False)
    
    def reset(self) -> None:
        self._integral = 0.0
        self._prev_error = 0.0
    
    def step(self, p: Perception, dt: float) -> CmdVel:
        if not p.valid:
            return CmdVel(0.0, 0.0, 0.0)
        
        error = wrap_pi(p.bearing_err)
        
        # Integral term with anti-windup
        self._integral += error * dt
        self._integral = float(np.clip(self._integral, -1.0, 1.0))
        
        # Derivative term
        derivative = (error - self._prev_error) / max(dt, 1e-6)
        self._prev_error = error
        
        # PID output for yaw rate
        yaw_rate = self.k_p * error + self.k_i * self._integral + self.k_d * derivative
        yaw_rate = float(np.clip(yaw_rate, -self.yaw_rate_max, self.yaw_rate_max))
        
        # Forward velocity (slow down when off-center)
        v_fwd = self.k_fwd * p.range_m * max(np.cos(error), 0.0)
        v_fwd = float(np.clip(v_fwd, 0.0, self.v_fwd_max))
        
        return CmdVel(v_fwd, 0.0, yaw_rate)


@dataclass
class PurePursuitLike(ControllerBase):
    """
    Geometric pursuit-style controller.
    
    Strategy:
    - Uses a "lookahead" distance concept from pure pursuit
    - Yaw gain increases as you get closer (prevents orbiting)
    - Forward speed based on range
    
    Pros: Smooth paths, good convergence behavior
    Cons: May be slower to acquire target initially
    
    Tuning tips:
    - lookahead: Larger = smoother paths but slower convergence
    - k_yaw: Base yaw gain (increases when close to target)
    """
    
    name: str = "Pursuit"
    
    # Gains
    lookahead: float = 2.0
    k_yaw: float = 1.2
    k_fwd: float = 0.8
    
    # Limits  
    v_fwd_max: float = 1.8
    yaw_rate_max: float = 1.2
    
    def step(self, p: Perception, dt: float) -> CmdVel:
        if not p.valid:
            return CmdVel(0.0, 0.0, 0.0)
        
        error = wrap_pi(p.bearing_err)
        
        # Adaptive yaw gain: stronger when close to prevent orbiting
        closeness = max(0.0, (self.lookahead - p.range_m) / max(self.lookahead, 1e-6))
        gain = self.k_yaw * (1.0 + 0.5 * closeness)
        yaw_rate = float(np.clip(gain * error, -self.yaw_rate_max, self.yaw_rate_max))
        
        # Forward velocity
        v_fwd = self.k_fwd * p.range_m
        v_fwd *= float(max(np.cos(error), 0.0))  # Slow when off-center
        v_fwd = float(np.clip(v_fwd, 0.0, self.v_fwd_max))
        
        return CmdVel(v_fwd, 0.0, yaw_rate)


# Registry for easy access
CONTROLLERS = {
    "p": PController,
    "pidyaw": PIDYawController,
    "pursuit": PurePursuitLike,
}


def make_controller(name: str, **kwargs) -> ControllerBase:
    """
    Factory function to create controllers by name.
    
    Args:
        name: Controller name ("p", "pidyaw", or "pursuit")
        **kwargs: Override default parameters
        
    Returns:
        Controller instance
        
    Example:
        ctrl = make_controller("pidyaw", k_p=2.5, k_i=0.5)
    """
    name = name.lower()
    if name not in CONTROLLERS:
        raise ValueError(f"Unknown controller: {name}. Available: {list(CONTROLLERS.keys())}")
    return CONTROLLERS[name](**kwargs)
