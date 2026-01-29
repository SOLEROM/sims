"""
Target motion scenarios for simulation.

Each scenario function takes the current time and returns a TargetState.
Available scenarios:

- circle: Target moves in a circle (good for testing tracking)
- line: Target moves in a line with sine wave (tests prediction)
- random_walk: Random motion (tests robustness to unpredictable targets)
- figure_eight: More complex path for advanced testing
- stationary: Static target (good for convergence testing)
"""

from __future__ import annotations

from dataclasses import dataclass
import numpy as np

from .models import TargetState


def target_circle(
    t: float,
    radius: float = 6.0,
    omega: float = 0.15,
    center: tuple[float, float] = (0.0, 0.0),
) -> TargetState:
    """
    Target moves in a circle.
    
    Args:
        t: Current time (seconds)
        radius: Circle radius (meters)
        omega: Angular velocity (rad/s)
        center: Circle center (x, y)
        
    Returns:
        Target position at time t
    """
    x = center[0] + radius * np.cos(omega * t)
    y = center[1] + radius * np.sin(omega * t)
    return TargetState(x=float(x), y=float(y))


def target_line(
    t: float,
    speed: float = 0.7,
    start: tuple[float, float] = (5.0, 0.0),
    oscillation: float = 2.0,
    osc_freq: float = 0.3,
) -> TargetState:
    """
    Target moves in a line with sinusoidal lateral oscillation.
    
    Args:
        t: Current time (seconds)
        speed: Forward speed (m/s)
        start: Starting position (x, y)
        oscillation: Lateral oscillation amplitude (meters)
        osc_freq: Oscillation frequency (rad/s)
        
    Returns:
        Target position at time t
    """
    x = start[0] + speed * t
    y = start[1] + oscillation * np.sin(osc_freq * t)
    return TargetState(x=float(x), y=float(y))


def target_random_walk(
    t: float,
    prev: TargetState,
    dt: float,
    step: float = 0.5,
    seed: int = 1,
) -> TargetState:
    """
    Target performs a random walk.
    
    Note: Uses time-based seeding for reproducibility.
    
    Args:
        t: Current time (seconds)
        prev: Previous target state
        dt: Time step (seconds)
        step: Step size standard deviation (m/s)
        seed: Random seed base
        
    Returns:
        New target position
    """
    rng = np.random.default_rng(seed=int(seed) + int(t / max(dt, 1e-6)))
    dx, dy = rng.normal(0.0, step, size=2)
    return TargetState(
        x=prev.x + float(dx) * dt,
        y=prev.y + float(dy) * dt,
    )


def target_figure_eight(
    t: float,
    scale: float = 5.0,
    omega: float = 0.15,
    center: tuple[float, float] = (0.0, 0.0),
) -> TargetState:
    """
    Target moves in a figure-eight pattern (lemniscate).
    
    Args:
        t: Current time (seconds)
        scale: Pattern scale (meters)
        omega: Angular velocity (rad/s)
        center: Pattern center (x, y)
        
    Returns:
        Target position at time t
    """
    theta = omega * t
    x = center[0] + scale * np.sin(theta)
    y = center[1] + scale * np.sin(theta) * np.cos(theta)
    return TargetState(x=float(x), y=float(y))


def target_stationary(
    t: float,
    position: tuple[float, float] = (6.0, 0.0),
) -> TargetState:
    """
    Stationary target (useful for convergence testing).
    
    Args:
        t: Current time (ignored)
        position: Fixed position (x, y)
        
    Returns:
        Target position
    """
    return TargetState(x=position[0], y=position[1])


# Registry for easy access
SCENARIOS = {
    "circle": target_circle,
    "line": target_line,
    "random": target_random_walk,
    "figure_eight": target_figure_eight,
    "stationary": target_stationary,
}


@dataclass
class ScenarioConfig:
    """Configuration for a scenario."""
    name: str
    kwargs: dict = None
    
    def __post_init__(self):
        if self.kwargs is None:
            self.kwargs = {}


def get_target(
    scenario: str | ScenarioConfig,
    t: float,
    prev: TargetState,
    dt: float,
    seed: int = 1,
) -> TargetState:
    """
    Get target position for a given scenario.
    
    Args:
        scenario: Scenario name or ScenarioConfig
        t: Current time
        prev: Previous target state (for random walk)
        dt: Time step
        seed: Random seed (for random walk)
        
    Returns:
        Target state at time t
    """
    if isinstance(scenario, ScenarioConfig):
        name = scenario.name.lower()
        kwargs = scenario.kwargs
    else:
        name = scenario.lower()
        kwargs = {}
    
    if name not in SCENARIOS:
        raise ValueError(f"Unknown scenario: {name}. Available: {list(SCENARIOS.keys())}")
    
    func = SCENARIOS[name]
    
    # Handle different function signatures
    if name == "random":
        return func(t, prev, dt, seed=seed, **kwargs)
    else:
        return func(t, **kwargs)
