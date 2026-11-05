#!/usr/bin/env python3
"""A stand-in for Mochlet's hook socket, for testing the relay without the app.

  scripts/fake-socket.py <socket-path> [--reply '{"permissionDecision":"allow"}'] [--count N] [--log file]

Every received line is appended to the log (one JSON line each). Lines with
"mochlet_wait": true get the --reply line back (nothing when --reply is omitted, which
makes the relay time out). Exits after N connections (default 1). Python 3.9 compatible.
"""
import argparse, json, os, socket, sys

ap = argparse.ArgumentParser()
ap.add_argument("path")
ap.add_argument("--reply", default=None)
ap.add_argument("--count", type=int, default=1)
ap.add_argument("--log", default=None)
a = ap.parse_args()

try:
    os.unlink(a.path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(a.path)
srv.listen(8)
sys.stdout.write("listening\n"); sys.stdout.flush()
for _ in range(a.count):
    conn, _ = srv.accept()
    conn.settimeout(5)
    buf = b""
    while b"\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            break
        buf += chunk
    line = buf.split(b"\n", 1)[0]
    out = line.decode("utf-8", "replace")
    if a.log:
        with open(a.log, "a") as f:
            f.write(out + "\n")
    else:
        sys.stdout.write(out + "\n"); sys.stdout.flush()
    try:
        obj = json.loads(out)
    except Exception:
        obj = {}
    if obj.get("mochlet_wait") and a.reply is not None:
        conn.sendall(a.reply.encode("utf-8") + b"\n")
    conn.close()
srv.close()
os.unlink(a.path)
