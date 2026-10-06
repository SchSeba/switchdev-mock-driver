#!/usr/bin/env python3
"""Unprivileged, interface-address-bound echo test; executed inside a test pod."""
import argparse
import json
import os
import socket
import time

p = argparse.ArgumentParser()
p.add_argument("source")
p.add_argument("destination")
p.add_argument("--count", type=int, default=400)
p.add_argument("--interval", type=float, default=0.01)
a = p.parse_args()
if not 1 <= a.count <= 100000 or not 0 <= a.interval <= 10:
    p.error("invalid test bounds")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((a.source, 0))
s.settimeout(2)
nonce = os.urandom(16)
received = 0
start = time.monotonic()
for seq in range(a.count):
    msg = nonce + seq.to_bytes(8, "big") + b"mock-smartnic-validation" * 4
    s.sendto(msg, (a.destination, 9000))
    try:
        reply, peer = s.recvfrom(65535)
        if reply == msg and peer == (a.destination, 9000):
            received += 1
    except socket.timeout:
        pass
    time.sleep(a.interval)
print(json.dumps({"source": a.source, "destination": a.destination,
                  "sent": a.count, "received": received, "lost": a.count-received,
                  "seconds": round(time.monotonic()-start, 3)}))
raise SystemExit(0 if received == a.count else 1)
