#!/usr/bin/env python3
"""Forward the AirPlay volume to CamillaDSP's Main fader.

shairport-sync appends the desired AirPlay volume as the last argument whenever
the volume changes. AirPlay volume runs 0.0 (loudest) to -30.0 (quietest), with
-144.0 as a mute sentinel.

Why this exists: CamillaDSP's Loudness filter compensates based on where the
Main fader sits. If the fader never moves, the filter applies a constant curve
and the whole point is lost. So the phone's slider has to reach it.

Pure standard library on purpose. This runs on every volume change on a
512 MB board, and the `websockets` package has churned its API repeatedly
across releases. Forty lines that speak exactly the two frames we need beat a
dependency that might break under us on an unattended upgrade.
"""

import base64
import json
import os
import socket
import struct
import sys
import syslog

HOST = os.environ.get("CAMILLADSP_HOST", "127.0.0.1")
PORT = int(os.environ.get("CAMILLADSP_PORT", "1234"))

# AirPlay reports -30.0 .. 0.0. That 30 dB span is too narrow to be a usable
# range on most systems -- the bottom of the slider would still be clearly
# audible. Stretch it onto 60 dB so the slider spans something useful.
#
# This constant also defines the scale that `reference_level` in filters.yml is
# expressed in. Change one, recalibrate the other.
AIRPLAY_MIN_DB = -30.0
TARGET_RANGE_DB = 60.0

MUTE_SENTINEL = -144.0
CONNECT_TIMEOUT = 2.0


def log(msg):
    """Log to syslog under a distinct tag.

    Deliberate: verifying that this script fires at all is the documented way
    to settle the ignore_volume_control question (DESIGN.md 8). Being able to
    run `journalctl -t air-spot-vol -f` and watch it react to the phone slider
    turns a guess into a two-minute test.
    """
    syslog.openlog(ident="air-spot-vol", facility=syslog.LOG_DAEMON)
    syslog.syslog(syslog.LOG_INFO, msg)


def ws_send(messages):
    """Minimal WebSocket client: connect, handshake, send frames, close."""
    key = base64.b64encode(os.urandom(16)).decode()
    handshake = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    ).encode()

    with socket.create_connection((HOST, PORT), timeout=CONNECT_TIMEOUT) as sock:
        sock.settimeout(CONNECT_TIMEOUT)
        sock.sendall(handshake)

        # Read just past the end of the HTTP response headers.
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(1024)
            if not chunk:
                raise ConnectionError("server closed during handshake")
            buf += chunk
        status_line = buf.split(b"\r\n", 1)[0]
        if b"101" not in status_line:
            raise ConnectionError(f"handshake refused: {status_line!r}")

        for msg in messages:
            sock.sendall(_frame(msg))

        # Close frame. We don't wait for a reply -- shairport-sync may invoke
        # this several times a second while a slider is being dragged, and
        # blocking on reads would queue processes up behind each other.
        sock.sendall(b"\x88\x80" + os.urandom(4))


def _frame(text):
    """Encode one masked client-to-server text frame."""
    payload = text.encode()
    header = b"\x81"  # FIN + opcode 0x1 (text)
    n = len(payload)
    if n < 126:
        header += struct.pack("!B", n | 0x80)
    elif n < 65536:
        header += struct.pack("!BH", 126 | 0x80, n)
    else:
        header += struct.pack("!BQ", 127 | 0x80, n)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return header + mask + masked


def main():
    if len(sys.argv) < 2:
        log("called with no volume argument -- ignoring")
        return 0

    try:
        airplay_vol = float(sys.argv[-1])
    except ValueError:
        log(f"unparseable volume {sys.argv[-1]!r} -- ignoring")
        return 0

    if airplay_vol <= MUTE_SENTINEL:
        messages = [json.dumps({"SetMute": True})]
        log("mute")
    else:
        # Clamp: shairport-sync should stay within range, but a value slightly
        # outside it must not become a positive gain.
        v = max(AIRPLAY_MIN_DB, min(0.0, airplay_vol))
        scaled = v * (TARGET_RANGE_DB / abs(AIRPLAY_MIN_DB))
        # Unmute alongside the level, so raising the volume from muted works
        # in one gesture rather than needing an explicit unmute.
        messages = [
            json.dumps({"SetVolume": round(scaled, 2)}),
            json.dumps({"SetMute": False}),
        ]
        log(f"airplay {airplay_vol:.1f} dB -> camilladsp {scaled:.1f} dB")

    try:
        ws_send(messages)
    except (OSError, ConnectionError) as e:
        # Never fail loudly. If CamillaDSP is mid-restart -- which happens
        # routinely, since it exits when playback stops -- there is nothing to
        # talk to, and the statefile will restore the level anyway. Blocking or
        # erroring here would just stall shairport-sync.
        log(f"could not reach camilladsp at {HOST}:{PORT} ({e}) -- volume not applied")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
