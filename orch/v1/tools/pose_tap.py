#!/usr/bin/env python3
"""pose_tap.py — MAVLink -> fg_protocol pose bridge (the px4-fg "pose tap").

Closes the physics -> renderer link of the px4-fg profile: PX4's stock SITL
rcS streams onboard-mode MAVLink to UDP 14540 (QGC keeps 14550 untouched);
this tap converts GLOBAL_POSITION_INT + ATTITUDE into the 9-field fg_protocol
datagram (fgear/craft_base_24/protocol/fg_protocol.xml) on UDP 15778, so the
external-fdm FlightGear camera follows whatever the PX4/gz physics does —
including anything flown from QGC. Design note: design/px4-fg-pose-tap.md.

stdlib only (fgear/feed_fdm.py style: layer tools carry no deps). The two RX
messages and one TX command are (de)coded by hand against the frozen MAVLink
v1/v2 wire format with the spec's CRC_EXTRA seeds. A wrong seed would mean
100% CRC rejects -> a loud "no MAVLink yet" stall, never silent garbage.

Usage:
  pose_tap.py                          # 14540 -> 127.0.0.1:15778, nadir cam
  pose_tap.py --north-up --verbose
  pose_tap.py --selftest               # offline unit + loopback socket tests
"""
import argparse
import math
import socket
import struct
import sys
import time

M2FT = 3.28084
MAGIC_V2, MAGIC_V1 = 0xFD, 0xFE
MAV_CMD_SET_MESSAGE_INTERVAL = 511

# msgid -> (name, payload_len, crc_extra, little-endian wire struct)
MSGS = {
    0:  ("HEARTBEAT", 9, 50, "<IBBBBB"),
    30: ("ATTITUDE", 28, 39, "<I6f"),          # ms, roll/pitch/yaw(+rates) rad
    33: ("GLOBAL_POSITION_INT", 28, 104, "<IiiiihhhH"),  # 1e7 deg, mm, cdeg
    76: ("COMMAND_LONG", 33, 152, "<7fHBBB"),
}


def x25(data, crc=0xFFFF):
    """CRC-16/MCRF4XX as used by MAVLink ('123456789' -> 0x6F91)."""
    for b in data:
        tmp = (b ^ (crc & 0xFF))
        tmp = (tmp ^ (tmp << 4)) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc


def frame_crc(body, msgid):
    return x25(bytes([MSGS[msgid][2]]), x25(body))


def build_v2(msgid, payload, seq, sysid=250, compid=190):
    body = struct.pack("<BBBBBB", len(payload), 0, 0, seq & 0xFF, sysid,
                       compid) + msgid.to_bytes(3, "little") + payload
    return bytes([MAGIC_V2]) + body + struct.pack("<H", frame_crc(body, msgid))


def parse_frames(buf):
    """Yield (msgid, payload padded to spec length) for every valid known
    message in a datagram; unknown msgids skipped by length, bad CRC dropped."""
    i, n = 0, len(buf)
    while i < n:
        magic = buf[i]
        if magic == MAGIC_V2 and i + 12 <= n:
            plen = buf[i + 1]
            sig = 13 if (buf[i + 2] & 0x01) else 0
            end = i + 10 + plen + 2 + sig
            if end > n:
                break
            msgid = int.from_bytes(buf[i + 7:i + 10], "little")
            body, crc = buf[i + 1:i + 10 + plen], buf[i + 10 + plen:i + 12 + plen]
        elif magic == MAGIC_V1 and i + 8 <= n:
            plen = buf[i + 1]
            end = i + 6 + plen + 2
            if end > n:
                break
            msgid = buf[i + 5]
            body, crc = buf[i + 1:i + 6 + plen], buf[i + 6 + plen:i + 8 + plen]
        else:
            i += 1
            continue
        spec = MSGS.get(msgid)
        if spec and struct.pack("<H", frame_crc(body, msgid)) == bytes(crc):
            payload = body[-plen:] if plen else b""
            yield msgid, payload + b"\x00" * (spec[1] - plen)  # v2 zero-trim pad
        i = end


def set_interval_cmd(msgid, hz, seq):
    """COMMAND_LONG / MAV_CMD_SET_MESSAGE_INTERVAL to autopilot (1,1)."""
    payload = struct.pack(MSGS[76][3], float(msgid), 1e6 / hz, 0, 0, 0, 0, 0,
                          MAV_CMD_SET_MESSAGE_INTERVAL, 1, 1, 0)
    return build_v2(76, payload, seq)


def to_datagram(gpi, att, cfg):
    """9-field fg_protocol line from unpacked GLOBAL_POSITION_INT (+ ATTITUDE,
    may be None). Field order/units: see protocol/fg_protocol.xml."""
    _, lat7, lon7, alt_mm, _rel, _vx, _vy, _vz, hdg_cd = gpi
    roll = pitch = yaw = 0.0
    if att is not None:
        roll, pitch, yaw = (math.degrees(att[1]), math.degrees(att[2]),
                            math.degrees(att[3]))
    heading = hdg_cd / 100.0 if hdg_cd != 65535 else yaw % 360.0
    view = (heading - cfg.north_trim) % 360.0 if cfg.north_up else cfg.view_offset
    return b"%f\t%f\t%f\t%f\t%f\t%.8f\t%.8f\t%f\t%f\n" % (
        cfg.cam_pitch, 0.0, heading,
        0.0 if cfg.flat else pitch, 0.0 if cfg.flat else roll,
        lat7 / 1e7, lon7 / 1e7,
        (alt_mm / 1000.0 + cfg.alt_offset_m) * M2FT, view)


def heartbeat(seq):
    """GCS-type HEARTBEAT — our 1 Hz hello to PX4's onboard link."""
    return build_v2(0, struct.pack(MSGS[0][3], 0, 6, 8, 0, 4, 3), seq)


def run(cfg):
    sys.stdout.reconfigure(line_buffering=True)  # tab/log output must be live
    remote_host, remote_port = cfg.mav_remote.rsplit(":", 1)
    remote = (remote_host, int(remote_port))
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind((cfg.mav_bind, cfg.mav_port))
    rx.settimeout(1.0)
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"[pose_tap] MAVLink :{cfg.mav_port} (hello -> {cfg.mav_remote}) -> "
          f"fg_protocol {cfg.fg_host}:{cfg.fg_port} (waiting for PX4 ...)")

    gpi = att = src = None
    seq = sent = ngpi = rc = 0
    t0 = time.monotonic()
    last_rx = t0
    last_out = last_req = last_note = last_hello = 0.0
    min_gap = 1.0 / cfg.max_hz
    try:
        while not (cfg.duration and time.monotonic() - t0 >= cfg.duration):
            now = time.monotonic()
            # PX4's UDP link re-learns its partner from the LAST packet it
            # received — anything that pokes 14580 steals the stream. Heartbeat
            # every 1s FROM the rx socket so the stream (re)targets our port;
            # re-request GPI+ATTITUDE rates every 5s (idempotent, and survives
            # a pxh Ctrl-C + ./runGzPX4.sh restart).
            if now - last_hello >= 1.0:
                rx.sendto(heartbeat(seq), remote)
                seq += 1
                last_hello = now
            if now - last_req >= 5.0:
                for msgid in (33, 30):
                    rx.sendto(set_interval_cmd(msgid, cfg.rate_hz, seq), remote)
                    seq += 1
                last_req = now
            try:
                data, addr = rx.recvfrom(65535)
            except socket.timeout:
                now = time.monotonic()
                if cfg.idle_exit and now - last_rx >= cfg.idle_exit:
                    print(f"[pose_tap] no MAVLink for {cfg.idle_exit:g}s "
                          "— exiting (rc 2) so the wrapper can re-ensure "
                          "the mavlink instance")
                    rc = 2
                    break
                if src is None and now - last_note > 10:
                    print("[pose_tap] still waiting for MAVLink "
                          f"from {cfg.mav_remote} ...")
                    last_note = now
                continue
            src = addr
            now = last_rx = time.monotonic()
            for msgid, payload in parse_frames(data):
                if msgid == 33:
                    gpi = struct.unpack(MSGS[33][3], payload)
                    ngpi += 1
                elif msgid == 30:
                    att = struct.unpack(MSGS[30][3], payload)
                else:
                    continue
                if gpi and now - last_out >= min_gap:
                    tx.sendto(to_datagram(gpi, att, cfg),
                              (cfg.fg_host, cfg.fg_port))
                    last_out = now
                    sent += 1
                    if sent == 1:
                        print(f"[pose_tap] first fix: lat {gpi[1] / 1e7:.6f} "
                              f"lon {gpi[2] / 1e7:.6f} alt {gpi[3] / 1000.0:.1f}m"
                              f" -> feeding FG")
            if cfg.verbose and now - last_note > 5:
                print(f"[pose_tap] {sent} datagrams sent ({ngpi} GPI total)")
                last_note = now
    except KeyboardInterrupt:
        pass
    print(f"[pose_tap] done: {sent} datagrams in {time.monotonic() - t0:.1f}s")
    return rc


# --------------------------------------------------------------- selftest ---
def selftest():
    import threading

    fails = []

    def check(name, cond):
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}")
        if not cond:
            fails.append(name)

    check("x25 CRC check-value ('123456789' -> 0x6F91)",
          x25(b"123456789") == 0x6F91)

    att = struct.pack(MSGS[30][3], 1000, 0.01, -0.02, math.pi / 2, 0, 0, 0)
    frame = build_v2(30, att, seq=7)
    got = list(parse_frames(frame))
    check("v2 roundtrip (ATTITUDE)", got == [(30, att)])
    corrupt = frame[:12] + bytes([frame[12] ^ 0xFF]) + frame[13:]
    check("bad CRC rejected", list(parse_frames(corrupt)) == [])

    gpi = struct.pack(MSGS[33][3], 2000, 473977420, 85455940, 488000, 0,
                      0, 0, 0, 9000)
    trimmed = gpi.rstrip(b"\x00")
    body = struct.pack("<BBBBBB", len(trimmed), 0, 0, 1, 1, 1) \
        + (33).to_bytes(3, "little") + trimmed
    zt = bytes([MAGIC_V2]) + body + struct.pack("<H", frame_crc(body, 33))
    check("v2 zero-trim payload padded", list(parse_frames(zt)) == [(33, gpi)])

    b1 = struct.pack("<BBBBB", len(att), 3, 1, 1, 30) + att
    v1 = bytes([MAGIC_V1]) + b1 + struct.pack("<H", frame_crc(b1, 30))
    check("v1 frame parsed", list(parse_frames(v1)) == [(30, att)])
    check("two frames in one datagram",
          [m for m, _ in parse_frames(frame + zt)] == [30, 33])

    cfg = argparse.Namespace(cam_pitch=-85.0, view_offset=0.0, north_up=False,
                             north_trim=0.0, flat=False, alt_offset_m=0.0)
    f = [float(x) for x in
         to_datagram(struct.unpack(MSGS[33][3], gpi),
                     struct.unpack(MSGS[30][3], att), cfg).split(b"\t")]
    check("datagram: 9 fields", len(f) == 9)
    check("datagram: cam pitch / lat / lon / alt_ft / hdg",
          f[0] == -85.0 and abs(f[5] - 47.397742) < 1e-7
          and abs(f[6] - 8.545594) < 1e-7
          and abs(f[7] - 488 * M2FT) < 0.1 and f[2] == 90.0)
    gpi_nohdg = struct.unpack(MSGS[33][3], gpi)[:8] + (65535,)
    f2 = [float(x) for x in
          to_datagram(gpi_nohdg, struct.unpack(MSGS[30][3], att),
                      cfg).split(b"\t")]
    check("hdg=UINT16_MAX falls back to ATTITUDE yaw",
          abs(f2[2] - 90.0) < 0.01)

    cmd = list(parse_frames(set_interval_cmd(33, 30, 0)))
    p = struct.unpack(MSGS[76][3], cmd[0][1])
    check("SET_MESSAGE_INTERVAL cmd (msgid 33 @ 30Hz to tgt 1,1)",
          cmd[0][0] == 76 and p[0] == 33.0 and abs(p[1] - 1e6 / 30) < 1
          and p[7] == MAV_CMD_SET_MESSAGE_INTERVAL and p[8] == 1 and p[9] == 1)

    # loopback end-to-end: fake PX4 -> run() -> fake FG listener
    fg = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fg.bind(("127.0.0.1", 0))
    fg.settimeout(3.0)
    px4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    px4.bind(("127.0.0.1", 0))
    px4.settimeout(3.0)
    live = argparse.Namespace(mav_bind="127.0.0.1", mav_port=0, fg_host="127.0.0.1",
                              fg_port=fg.getsockname()[1],
                              mav_remote="127.0.0.1:%d" % px4.getsockname()[1],
                              cam_pitch=-85.0,
                              view_offset=0.0, north_up=False, north_trim=0.0,
                              flat=False, alt_offset_m=0.0, max_hz=200.0,
                              rate_hz=30, duration=2.0, idle_exit=0.0,
                              verbose=False)
    # run() binds port 0 -> find the real port via the socket it creates: give
    # it a fixed ephemeral port instead
    tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tmp.bind(("127.0.0.1", 0))
    live.mav_port = tmp.getsockname()[1]
    tmp.close()
    th = threading.Thread(target=run, args=(live,), daemon=True)
    th.start()
    time.sleep(0.3)
    for s in range(20):
        px4.sendto(build_v2(33, gpi, s) + build_v2(30, att, s),
                   ("127.0.0.1", live.mav_port))
        time.sleep(0.02)
    try:
        out, _ = fg.recvfrom(4096)
        lat = float(out.split(b"\t")[5])
        check("loopback: fg datagram carries PX4 lat", abs(lat - 47.397742) < 1e-6)
    except socket.timeout:
        check("loopback: fg datagram carries PX4 lat", False)
    got_ids = set()
    try:
        for _ in range(4):
            req, _ = px4.recvfrom(4096)
            got_ids |= {m for m, _ in parse_frames(req)}
            if {0, 76} <= got_ids:
                break
    except socket.timeout:
        pass
    check("loopback: tap sent hello heartbeat + rate requests to PX4 side",
          {0, 76} <= got_ids)
    th.join(3.0)
    fg.close(), px4.close()

    # idle-exit: silent link -> rc 2 promptly (wrapper-loop contract)
    tmp2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tmp2.bind(("127.0.0.1", 0))
    idle = argparse.Namespace(**{**vars(live), "mav_port": tmp2.getsockname()[1],
                                 "mav_remote": "127.0.0.1:9",
                                 "idle_exit": 1.2, "duration": 0.0})
    tmp2.close()
    t = time.monotonic()
    check("idle-exit: rc 2 within a few seconds on a silent link",
          run(idle) == 2 and time.monotonic() - t < 5)

    print(f"selftest: {'FAIL: ' + ', '.join(fails) if fails else 'all PASS'}")
    return 0 if not fails else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mav-bind", default="0.0.0.0")
    ap.add_argument("--mav-port", type=int, default=14540,
                    help="PX4 SITL onboard MAVLink UDP port (QGC keeps 14550)")
    ap.add_argument("--mav-remote", default="127.0.0.1:14580",
                    help="PX4's side of the onboard link — hello heartbeats "
                         "go here so the stream (re)targets us")
    ap.add_argument("--fg-host", default="127.0.0.1")
    ap.add_argument("--fg-port", type=int, default=15778,
                    help="FG external-fdm generic-in UDP port")
    ap.add_argument("--cam-pitch", type=float, default=-85.0,
                    help="view pitch-offset-deg (-85 ~= nadir drone camera)")
    ap.add_argument("--view-offset", type=float, default=0.0,
                    help="fixed view heading-offset-deg (0 = heading-up/FPV)")
    ap.add_argument("--north-up", action="store_true",
                    help="pin window-top to azimuth --north-trim "
                         "(sends heading-trim, see fg_protocol.xml field 9)")
    ap.add_argument("--north-trim", type=float, default=0.0)
    ap.add_argument("--flat", action="store_true",
                    help="zero vehicle pitch/roll (feed position+heading only)")
    ap.add_argument("--alt-offset-m", type=float, default=0.0,
                    help="added to AMSL altitude before the ft conversion")
    ap.add_argument("--rate-hz", type=int, default=30,
                    help="stream rate requested from PX4 (SET_MESSAGE_INTERVAL)")
    ap.add_argument("--max-hz", type=float, default=60.0,
                    help="output datagram rate cap")
    ap.add_argument("--idle-exit", type=float, default=0.0,
                    help="exit rc 2 after this many s without MAVLink "
                         "(lets a wrapper loop re-ensure the instance); "
                         "0 = wait forever")
    ap.add_argument("--duration", type=float, default=0.0, help="0 = forever")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    cfg = ap.parse_args()
    if cfg.selftest:
        sys.exit(selftest())
    sys.exit(run(cfg))


if __name__ == "__main__":
    main()
