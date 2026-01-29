"""
Drone Target Tracking Simulator

A perception-based target tracking simulator for drones with:
- Multiple control algorithms (P, PID, Pure Pursuit)
- Various target motion scenarios
- FCU-like velocity limiting
- Comprehensive metrics

Quick Start:
    from drone_tracker import Simulator, SimConfig
    
    sim = Simulator()
    result = sim.run(controller="pidyaw", scenario="circle")
    print(result.metrics)
    sim.plot(result)
"""

from .models import (
    DroneState,
    TargetState,
    Perception,
    CmdVel,
    FCUSetpointFilter,
    wrap_pi,
    body_to_world,
)

from .controllers import (
    ControllerBase,
    PController,
    PIDYawController,
    PurePursuitLike,
    make_controller,
    CONTROLLERS,
)

from .scenarios import (
    target_circle,
    target_line,
    target_random_walk,
    target_figure_eight,
    target_stationary,
    get_target,
    SCENARIOS,
)

from .metrics import (
    SimulationMetrics,
    summarize,
    compare_runs,
    print_comparison,
)

from .simulator import (
    SimConfig,
    Simulator,
    SimulationResult,
    perception_model,
)

__version__ = "0.1.0"

__all__ = [
    # Models
    "DroneState",
    "TargetState", 
    "Perception",
    "CmdVel",
    "FCUSetpointFilter",
    "wrap_pi",
    "body_to_world",
    # Controllers
    "ControllerBase",
    "PController",
    "PIDYawController",
    "PurePursuitLike",
    "make_controller",
    "CONTROLLERS",
    # Scenarios
    "target_circle",
    "target_line",
    "target_random_walk",
    "target_figure_eight",
    "target_stationary",
    "get_target",
    "SCENARIOS",
    # Metrics
    "SimulationMetrics",
    "summarize",
    "compare_runs",
    "print_comparison",
    # Simulator
    "SimConfig",
    "Simulator",
    "SimulationResult",
    "perception_model",
]
