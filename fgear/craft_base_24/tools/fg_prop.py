#!/usr/bin/env python3
"""fg_prop.py — read/write FlightGear properties over the props telnet server.

The verify-without-a-screenshot tool: a renderer instance exposes its whole
property tree on --telnet (default 15777), so position, view and hook state can
be asserted from scripts even when the window is unmapped or headless.

  fg_prop.py get /position/latitude-deg
  fg_prop.py --port 15777 get /addobj/count
  fg_prop.py set /addobj/seq 1
  fg_prop.py --raw get /sim/current-view/raw-orientation   # print server line as-is

Prints the bare value (or the raw response line with --raw). Exit 1 on timeout
or missing value.
"""
import argparse
import re
import socket
import sys


def talk(host, port, line, timeout=5.0):
    s = socket.create_connection((host, port), timeout=timeout)
    s.sendall((line + "\r\n").encode())
    s.settimeout(timeout)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    finally:
        s.close()
    return buf.decode(errors="replace").strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15777)
    ap.add_argument("--raw", action="store_true", help="print the raw response line")
    ap.add_argument("cmd", choices=["get", "set"])
    ap.add_argument("prop")
    ap.add_argument("value", nargs="?")
    args = ap.parse_args()

    if args.cmd == "set":
        if args.value is None:
            sys.exit("set needs a value")
        talk(args.host, args.port, f"set {args.prop} {args.value}")
        return

    resp = talk(args.host, args.port, f"get {args.prop}")
    if args.raw:
        print(resp)
        return
    m = re.search(r"=\s*'([^']*)'", resp)
    if not m:
        print(resp, file=sys.stderr)
        sys.exit(1)
    print(m.group(1))


if __name__ == "__main__":
    main()
