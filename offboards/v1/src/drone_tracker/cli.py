"""
Command-line interface for the drone tracking simulator.

Usage:
    drone-sim --controller PIDYaw --scenario circle --plot
"""

import argparse
import sys

from .simulator import Simulator, SimConfig


def main():
    """Main entry point for CLI."""
    parser = argparse.ArgumentParser(
        description="Drone target tracking simulator",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    
    # Controller and scenario
    parser.add_argument(
        "--controller", "-c",
        default="P",
        choices=["P", "PIDYaw", "Pursuit"],
        help="Control algorithm",
    )
    parser.add_argument(
        "--scenario", "-s",
        default="circle",
        choices=["circle", "line", "random", "figure_eight", "stationary"],
        help="Target motion scenario",
    )
    
    # Timing
    parser.add_argument("--duration", type=float, default=40.0, help="Simulation duration (s)")
    parser.add_argument("--sim-hz", type=float, default=200.0, help="Physics rate (Hz)")
    parser.add_argument("--ctrl-hz", type=float, default=30.0, help="Controller rate (Hz)")
    
    # Initial conditions
    parser.add_argument("--x0", type=float, default=-2.0, help="Drone initial x (m)")
    parser.add_argument("--y0", type=float, default=-2.0, help="Drone initial y (m)")
    parser.add_argument("--yaw0-deg", type=float, default=45.0, help="Drone initial yaw (deg)")
    parser.add_argument("--tx0", type=float, default=6.0, help="Target initial x (m)")
    parser.add_argument("--ty0", type=float, default=0.0, help="Target initial y (m)")
    
    # Noise
    parser.add_argument("--noise-bearing", type=float, default=0.02, help="Bearing noise std (rad)")
    parser.add_argument("--noise-range", type=float, default=0.05, help="Range noise std (m)")
    parser.add_argument("--seed", type=int, default=1, help="Random seed")
    
    # FCU limits
    parser.add_argument("--v-max", type=float, default=2.0, help="Max velocity (m/s)")
    parser.add_argument("--a-max", type=float, default=2.5, help="Max acceleration (m/s²)")
    parser.add_argument("--yaw-rate-max", type=float, default=1.5, help="Max yaw rate (rad/s)")
    
    # Metrics
    parser.add_argument("--capture-radius", type=float, default=0.7, help="Capture radius (m)")
    
    # Output
    parser.add_argument("--plot", "-p", action="store_true", help="Show plots")
    
    args = parser.parse_args()
    
    # Create config
    config = SimConfig(
        duration=args.duration,
        sim_hz=args.sim_hz,
        ctrl_hz=args.ctrl_hz,
        drone_x0=args.x0,
        drone_y0=args.y0,
        drone_yaw0_deg=args.yaw0_deg,
        target_x0=args.tx0,
        target_y0=args.ty0,
        noise_bearing=args.noise_bearing,
        noise_range=args.noise_range,
        v_max=args.v_max,
        a_max=args.a_max,
        yaw_rate_max=args.yaw_rate_max,
        capture_radius=args.capture_radius,
        seed=args.seed,
    )
    
    # Run simulation
    sim = Simulator(config)
    result = sim.run(controller=args.controller, scenario=args.scenario)
    
    # Print results
    print("\n" + "=" * 50)
    print(f"Controller: {args.controller}")
    print(f"Scenario:   {args.scenario}")
    print("=" * 50)
    print(result.metrics)
    
    # Plot if requested
    if args.plot:
        sim.plot(result)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
