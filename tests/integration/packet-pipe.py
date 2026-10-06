#!/usr/bin/env python3
"""Actual raw Ethernet send/receive with bounded readiness and duplicate checks."""
import json
import selectors
import socket
import subprocess
import sys
import time

ETHERTYPE = 0x88B5


def receive(device, frame):
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETHERTYPE)) as sock:
        sock.bind((device, 0))
        sock.settimeout(0.2)
        print("READY", flush=True)
        packets = 0
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            if addr[2] != socket.PACKET_OUTGOING and data == frame:
                packets += 1
        print(json.dumps({"received": packets}), flush=True)


def command(namespace, args):
    return (["ip", "netns", "exec", namespace] if namespace != "-" else []) + args


def probe(source_ns, source, dest_ns, dest, frame, expected):
    receiver = subprocess.Popen(command(dest_ns, [sys.executable, __file__, "receive", dest, frame.hex()]),
                                stdout=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(receiver.stdout, selectors.EVENT_READ)
            assert ready.select(5), "receiver readiness timed out"
            assert receiver.stdout.readline().strip() == "READY", "receiver failed before binding"
        subprocess.run(command(source_ns, [sys.executable, __file__, "send", source, frame.hex()]),
                       check=True, timeout=5)
        output, _ = receiver.communicate(timeout=5)
        assert receiver.returncode == 0, "receiver failed"
        result = json.loads(output)
        assert result["received"] == expected, (result, expected)
        print(json.dumps({"source": source, "dest": dest, "expected": expected, **result}))
    finally:
        if receiver.poll() is None:
            receiver.kill()
            receiver.wait(timeout=5)


if __name__ == "__main__":
    mode, *args = sys.argv[1:]
    if mode == "receive":
        receive(args[0], bytes.fromhex(args[1]))
    elif mode == "send":
        with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETHERTYPE)) as sock:
            sock.bind((args[0], 0))
            sock.send(bytes.fromhex(args[1]))
    elif mode == "probe":
        source_ns, source, dest_ns, dest, src_mac, dst_mac, expected = args
        frame = bytes.fromhex(dst_mac.replace(":", "") + src_mac.replace(":", ""))
        frame += ETHERTYPE.to_bytes(2, "big") + b"mock-smartnic-payload-" * 4
        probe(source_ns, source, dest_ns, dest, frame, int(expected))
    else:
        raise ValueError("expected receive, send, or probe")
