#!/usr/bin/env python3
"""feed_fdm.py — reference pose sender for external-fdm renderer mode. stdlib only.

Sends the 9-field fg_protocol generic-protocol datagram (tab-separated %f,
newline-terminated) that drives FlightGear's position/orientation + camera view
(see protocol/fg_protocol.xml). Use it to validate a renderer instance without
any outer pipeline, or as the template for a real bridge.

Examples:
  # hover 40 m over KSFO, nadir camera, 3 s
  feed_fdm.py --lat 37.613544 --lon -122.357172 --alt-m 40 --duration 3

  # fly a 100 m-radius circle at 20 Hz, heading following the path
  feed_fdm.py --lat 37.6135 --lon -122.3572 --alt-m 60 --circle-m 100 --duration 30
"""
import argparse
import math
import socket
import time

M2FT = 3.28084


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15778, help="FG generic-in UDP port")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--alt-m", type=float, default=40.0, help="altitude, meters AMSL")
    ap.add_argument("--heading", type=float, default=0.0)
    ap.add_argument("--cam-pitch", type=float, default=-85.0,
                    help="view pitch-offset-deg (-85 ~= nadir drone camera)")
    ap.add_argument("--view-offset", type=float, default=0.0,
                    help="view heading-offset-deg (0 = heading-up/FPV; "
                         "send 'heading - TRIM' for north-up, see fg_protocol.xml)")
    ap.add_argument("--circle-m", type=float, default=0.0,
                    help="radius of a circular path around lat/lon (0 = hold)")
    ap.add_argument("--period-s", type=float, default=30.0, help="circle period")
    ap.add_argument("--hz", type=float, default=20.0)
    ap.add_argument("--duration", type=float, default=10.0, help="seconds (0 = forever)")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dt = 1.0 / args.hz
    t0 = time.time()
    n = 0
    mlat = 111320.0
    mlon = 111320.0 * math.cos(math.radians(args.lat))
    print(f"feeding {args.host}:{args.port} at {args.hz:g} Hz "
          f"({'circle %gm' % args.circle_m if args.circle_m else 'hold'}) ...")
    try:
        while True:
            t = time.time() - t0
            if args.duration and t >= args.duration:
                break
            if args.circle_m > 0:
                w = 2 * math.pi * t / args.period_s
                lat = args.lat + args.circle_m * math.sin(w) / mlat
                lon = args.lon + args.circle_m * math.cos(w) / mlon
                heading = (math.degrees(w) + 90.0) % 360.0  # tangent to the circle
            else:
                lat, lon, heading = args.lat, args.lon, args.heading
            pkt = b"%f\t%f\t%f\t%f\t%f\t%.8f\t%.8f\t%f\t%f\n" % (
                args.cam_pitch,          # /sim/current-view/pitch-offset-deg
                0.0,                     # /sim/current-view/roll-offset-deg
                heading,                 # /orientation/heading-deg
                0.0,                     # /orientation/pitch-deg
                0.0,                     # /orientation/roll-deg
                lat,                     # /position/latitude-deg
                lon,                     # /position/longitude-deg
                args.alt_m * M2FT,       # /position/altitude-ft
                args.view_offset,        # /sim/current-view/heading-offset-deg
            )
            sock.sendto(pkt, (args.host, args.port))
            n += 1
            time.sleep(dt)
    except KeyboardInterrupt:
        pass
    print(f"sent {n} datagrams in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
