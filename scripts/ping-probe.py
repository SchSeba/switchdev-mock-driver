#!/usr/bin/env python3
"""Actual address-bound ICMP echo via Linux unprivileged ping sockets."""
import argparse
import json
import os
import socket
import struct
import time

p = argparse.ArgumentParser()
p.add_argument('source')
p.add_argument('destination')
p.add_argument('--count', type=int, default=10)
a = p.parse_args()
if not 1 <= a.count <= 1000:
    p.error('count must be 1..1000')


def checksum(packet):
    if len(packet) % 2:
        packet += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(packet) // 2), packet))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


received = 0
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP) as sock:
    sock.bind((a.source, 0))
    sock.settimeout(2)
    nonce = os.urandom(16)
    for seq in range(a.count):
        payload = nonce + seq.to_bytes(4, 'big') + b'mock-smartnic-icmp'
        request = struct.pack('!BBHHH', 8, 0, 0, 0, seq) + payload
        request = request[:2] + struct.pack('!H', checksum(request)) + request[4:]
        sock.sendto(request, (a.destination, 0))
        identifier = sock.getsockname()[1]
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            sock.settimeout(max(.01, deadline - time.monotonic()))
            try:
                reply, peer = sock.recvfrom(65535)
            except socket.timeout:
                break
            if len(reply) < 8:
                continue
            kind, code, _, reply_id, reply_seq = struct.unpack('!BBHHH', reply[:8])
            if (kind == 0 and code == 0 and peer[0] == a.destination and
                    reply_id == identifier and reply_seq == seq and reply[8:] == payload and
                    checksum(reply) == 0):
                received += 1
                break
        time.sleep(.1)
print(json.dumps({'protocol': 'icmp', 'source': a.source, 'destination': a.destination,
                  'sent': a.count, 'received': received, 'lost': a.count - received}))
raise SystemExit(0 if received == a.count else 1)
