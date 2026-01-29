"""
Core data models for the drone tracking simulator.

This module defines the state representations for:
- DroneState: The drone's position, orientation, and velocity
- TargetState: The target's position
- Perception: What the drone "sees" (bearing and range to target)
- CmdVel: Velocity commands sent to the drone
- FCUSetpointFilter: Simulates flight controller smoothing/limits
"""

from __future__ import annotations

from dataclasses import dataclass, field
import numpy as np


def wrap_pi(angle: float) -> float:
    """Wrap angle to [-π, π] range."""
    return float((angle + np.pi) % (2.0 * np.pi) - np.pi)


def body_to_world(v_fwd: float, v_lat: float, yaw: float) -> tuple[float, float]:
    """
    Convert body-frame velocities to world-frame velocities.
    
    Body frame:
        +fwd = forward (x_body)
        +lat = left (y_body)
    
    World frame:
        +x = east, +y = north
    
    Args:
        v_fwd: Forward velocity in body frame (m/s)
        v_lat: Lateral velocity in body frame (m/s, positive = left)
        yaw: Heading angle (rad, 0 = east, π/2 = north)
    
    Returns:
        (vx, vy) in world frame
    """
    c, s = np.cos(yaw), np.sin(yaw)
    vx = c * v_fwd - s * v_lat
    vy = s * v_fwd + c * v_lat
    return float(vx), float(vy)


@dataclass
class DroneState:
    """
    Full drone state in world frame.
    
    Attributes:
        x, y: Position (meters)
        yaw: Heading (radians, 0 = +x direction)
        vx, vy: Velocity in world frame (m/s)
    """
    x: float = 0.0
    y: float = 0.0
    yaw: float = 0.0
    vx: float = 0.0
    vy: float = 0.0
    
    def copy(self) -> DroneState:
        return DroneState(self.x, self.y, self.yaw, self.vx, self.vy)


@dataclass
class TargetState:
    """
    Target position in world frame.
    
    Attributes:
        x, y: Position (meters)
    """
    x: float = 5.0
    y: float = 0.0
    
    def copy(self) -> TargetState:
        return TargetState(self.x, self.y)


@dataclass
class Perception:
    """
    What the drone's perception system outputs to the controller.
    
    This simulates a camera/sensor that can detect:
    - bearing_err: Angle to target in drone's body frame (rad)
                   0 = target straight ahead, >0 = target to the left
    - range_m: Distance to target (meters)
    - valid: Whether the perception is valid (target visible)
    """
    bearing_err: float
    range_m: float
    valid: bool = True


@dataclass
class CmdVel:
    """
    Velocity command (setpoint) in body frame.
    
    This is what the controller outputs and sends to the flight controller.
    
    Attributes:
        v_fwd: Forward velocity command (m/s)
        v_lat: Lateral velocity command (m/s, positive = left)
        yaw_rate: Yaw rate command (rad/s, positive = counter-clockwise)
    """
    v_fwd: float = 0.0
    v_lat: float = 0.0
    yaw_rate: float = 0.0


@dataclass
class FCUSetpointFilter:
    """
    Simulates the Flight Controller Unit (FCU) smoothing and limits.
    
    Real drones don't instantly achieve commanded velocities—the FCU
    enforces acceleration limits and smooths the commands. This class
    mimics that behavior.
    
    Attributes:
        v_max: Maximum velocity magnitude (m/s)
        a_max: Maximum acceleration (m/s²)
        yaw_rate_max: Maximum yaw rate (rad/s)
        yaw_acc_max: Maximum yaw acceleration (rad/s²)
    """
    v_max: float = 2.0
    a_max: float = 2.5
    yaw_rate_max: float = 1.5
    yaw_acc_max: float = 3.0
    
    # Internal state (current achieved values)
    _v_fwd: float = field(default=0.0, repr=False)
    _v_lat: float = field(default=0.0, repr=False)
    _yaw_rate: float = field(default=0.0, repr=False)
    
    def reset(self) -> None:
        """Reset internal state to zero."""
        self._v_fwd = 0.0
        self._v_lat = 0.0
        self._yaw_rate = 0.0
    
    def step(self, cmd: CmdVel, dt: float) -> CmdVel:
        """
        Apply rate limits to commanded velocity.
        
        Args:
            cmd: Desired velocity command
            dt: Time step (seconds)
            
        Returns:
            Rate-limited velocity command
        """
        # Clamp desired values to max velocity
        des_v_fwd = np.clip(cmd.v_fwd, -self.v_max, self.v_max)
        des_v_lat = np.clip(cmd.v_lat, -self.v_max, self.v_max)
        des_yaw_rate = np.clip(cmd.yaw_rate, -self.yaw_rate_max, self.yaw_rate_max)
        
        # Apply acceleration limits
        dv = self.a_max * dt
        self._v_fwd += np.clip(des_v_fwd - self._v_fwd, -dv, dv)
        self._v_lat += np.clip(des_v_lat - self._v_lat, -dv, dv)
        
        dy = self.yaw_acc_max * dt
        self._yaw_rate += np.clip(des_yaw_rate - self._yaw_rate, -dy, dy)
        
        return CmdVel(self._v_fwd, self._v_lat, self._yaw_rate)
