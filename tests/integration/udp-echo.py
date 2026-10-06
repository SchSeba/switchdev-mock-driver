#!/usr/bin/env python3
"""Bounded, unprivileged UDP echo for actual namespace/pod traffic tests."""
import socket
import sys
import time

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind((sys.argv[1], 9000))
    sock.settimeout(1)
    deadline = time.monotonic() + 90
    print('READY', flush=True)
    while time.monotonic() < deadline:
        try:
            packet, peer = sock.recvfrom(65535)
        except socket.timeout:
            continue
        sock.sendto(packet, peer)
