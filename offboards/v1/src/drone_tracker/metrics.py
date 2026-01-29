"""
Metrics and analysis for simulation results.

Key metrics:
- rms_dist: Root-mean-square tracking distance (lower = better tracking)
- min_dist: Closest approach (lower = better)
- t_capture: Time to reach capture radius (lower = faster acquisition)
- control_energy: Sum of squared commands (lower = more efficient)
"""

from __future__ import annotations

from dataclasses import dataclass
import numpy as np


def rms(x: np.ndarray) -> float:
    """Compute root-mean-square of an array."""
    return float(np.sqrt(np.mean(np.square(x))))


@dataclass
class SimulationMetrics:
    """Container for simulation metrics."""
    
    rms_dist: float           # RMS tracking distance
    min_dist: float           # Minimum distance achieved
    max_dist: float           # Maximum distance
    mean_dist: float          # Mean distance
    t_capture: float          # Time to first capture (inf if never)
    t_in_capture: float       # Total time within capture radius
    control_energy_v: float   # Mean squared velocity magnitude
    control_energy_yaw: float # Mean squared yaw rate
    
    def __str__(self) -> str:
        lines = [
            "Simulation Metrics:",
            f"  RMS Distance:      {self.rms_dist:.3f} m",
            f"  Min Distance:      {self.min_dist:.3f} m",
            f"  Max Distance:      {self.max_dist:.3f} m",
            f"  Mean Distance:     {self.mean_dist:.3f} m",
        ]
        if np.isfinite(self.t_capture):
            lines.append(f"  Time to Capture:   {self.t_capture:.2f} s")
        else:
            lines.append(f"  Time to Capture:   not captured")
        lines.extend([
            f"  Time in Capture:   {self.t_in_capture:.2f} s",
            f"  Control Energy (v):   {self.control_energy_v:.3f}",
            f"  Control Energy (yaw): {self.control_energy_yaw:.3f}",
        ])
        return "\n".join(lines)
    
    def to_dict(self) -> dict:
        """Convert to dictionary for easy comparison."""
        return {
            "rms_dist": self.rms_dist,
            "min_dist": self.min_dist,
            "max_dist": self.max_dist,
            "mean_dist": self.mean_dist,
            "t_capture": self.t_capture,
            "t_in_capture": self.t_in_capture,
            "control_energy_v": self.control_energy_v,
            "control_energy_yaw": self.control_energy_yaw,
        }


def summarize(run: dict, capture_radius: float = None) -> SimulationMetrics:
    """
    Compute metrics from a simulation run.
    
    Args:
        run: Dictionary containing simulation data with keys:
            - t: time array
            - dist: distance to target array
            - cmd_v: velocity command magnitude array
            - cmd_yaw: yaw rate command array
            - capture_radius: (optional) radius for capture detection
            
    Returns:
        SimulationMetrics object
    """
    t = run["t"]
    dist = run["dist"]
    cmd_v = run["cmd_v"]
    cmd_yaw = run["cmd_yaw"]
    
    if capture_radius is None:
        capture_radius = run.get("capture_radius", 0.7)
    
    # Find capture time
    capture_mask = dist <= capture_radius
    capture_indices = np.where(capture_mask)[0]
    t_capture = float(t[capture_indices[0]]) if capture_indices.size > 0 else float("inf")
    
    # Time spent in capture zone
    dt = t[1] - t[0] if len(t) > 1 else 0.0
    t_in_capture = float(np.sum(capture_mask) * dt)
    
    return SimulationMetrics(
        rms_dist=rms(dist),
        min_dist=float(np.min(dist)),
        max_dist=float(np.max(dist)),
        mean_dist=float(np.mean(dist)),
        t_capture=t_capture,
        t_in_capture=t_in_capture,
        control_energy_v=float(np.mean(cmd_v ** 2)),
        control_energy_yaw=float(np.mean(cmd_yaw ** 2)),
    )


def compare_runs(runs: dict[str, dict], capture_radius: float = 0.7) -> dict[str, SimulationMetrics]:
    """
    Compare multiple simulation runs.
    
    Args:
        runs: Dictionary mapping run name to run data
        capture_radius: Radius for capture detection
        
    Returns:
        Dictionary mapping run name to metrics
    """
    return {name: summarize(run, capture_radius) for name, run in runs.items()}


def print_comparison(metrics: dict[str, SimulationMetrics]) -> None:
    """Pretty-print a comparison of multiple runs."""
    print("\n" + "=" * 70)
    print("COMPARISON")
    print("=" * 70)
    
    # Header
    names = list(metrics.keys())
    print(f"{'Metric':<20}", end="")
    for name in names:
        print(f"{name:>15}", end="")
    print()
    print("-" * 70)
    
    # Rows
    fields = ["rms_dist", "min_dist", "t_capture", "control_energy_v", "control_energy_yaw"]
    labels = ["RMS Dist (m)", "Min Dist (m)", "T Capture (s)", "Energy (v)", "Energy (yaw)"]
    
    for field, label in zip(fields, labels):
        print(f"{label:<20}", end="")
        for name in names:
            val = getattr(metrics[name], field)
            if np.isfinite(val):
                print(f"{val:>15.3f}", end="")
            else:
                print(f"{'N/A':>15}", end="")
        print()
