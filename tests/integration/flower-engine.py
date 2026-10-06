#!/usr/bin/env python3
"""Actual TC callbacks and packet engine checks on the attested guest PF."""
import ipaddress
import json
import pathlib
import socket
import struct
import subprocess
import sys
import time

bdf = sys.argv[1]
root = pathlib.Path('/sys/bus/pci/devices') / bdf
assert (root / 'driver').resolve().name == 'mock_smartnic_pf'
ports = json.loads(subprocess.check_output(['devlink', '-j', 'port', 'show']))['port']
reps = {p['vfnum']: p['netdev'] for name, p in ports.items()
        if name.startswith('pci/' + bdf + '/') and p['flavour'] == 'pcivf'}
r0, r1 = reps[0], reps[1]
v0 = next((root / 'virtfn0' / 'net').iterdir()).name
v1 = next((root / 'virtfn1' / 'net').iterdir()).name
uplink = next((root / 'net').iterdir()).name
debug = pathlib.Path('/sys/kernel/debug/mock_smartnic') / bdf


def run(*args, reject=None):
    result = subprocess.run(args, text=True, capture_output=True, timeout=15)
    if reject:
        print('REJECT', ' '.join(args), result.stderr.strip(), flush=True)
        assert result.returncode != 0 and reject in result.stderr, result
    else:
        assert result.returncode == 0, (args, result.stderr)
    return result.stdout


def flower(operation, priority, *predicate, action=None, reject=None, chain=0, handle=None):
    return run('tc', 'filter', operation, 'dev', r0, 'ingress', 'protocol', 'ip',
               'pref', str(priority), 'chain', str(chain), 'handle', str(handle or priority),
               'flower', 'skip_sw', *predicate, 'action',
               *(action or ['mirred', 'egress', 'redirect', 'dev', r1]), reject=reject)


def flows():
    return json.loads((debug / 'flows').read_text())['flows']


def count(priority):
    return sum(f['packets'] for f in flows() if f['priority'] == priority)


def checksum(data):
    words = struct.unpack('!' + 'H' * (len(data) // 2), data)
    total = sum(words)
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


mac = bytes.fromhex(pathlib.Path('/sys/class/net', v0, 'address').read_text().strip().replace(':', ''))
dst_mac = bytes.fromhex(pathlib.Path('/sys/class/net', v1, 'address').read_text().strip().replace(':', ''))


def packet(src='192.0.2.1', dst='192.0.2.2', proto=17, fragment=0, options=b'',
           payload=None, total=None, version=4):
    payload = payload if payload is not None else struct.pack('!HHHH', 1111, 4242, 16, 0) + b'k05-test'
    ihl = 5 + len(options) // 4
    length = total if total is not None else ihl * 4 + len(payload)
    header = struct.pack('!BBHHHBBH4s4s', version * 16 + ihl, 0, length, 100,
                         fragment, 64, proto, 0, ipaddress.ip_address(src).packed,
                         ipaddress.ip_address(dst).packed) + options
    header = header[:10] + struct.pack('!H', checksum(header)) + header[12:]
    return dst_mac + mac + b'\x08\x00' + header + payload


def send(frame, priority, expected):
    before = count(priority)
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800)) as sock:
        sock.bind((v0, 0))
        sock.send(frame)
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        after = count(priority)
        if after != before:
            break
        time.sleep(.02)
    assert after - before == expected, (priority, after, before, expected, frame.hex())
    print('PACKET', priority, expected, 'PASS', flush=True)


qdisc_owned = False
try:
    for dev in (r0, r1, v0, v1):
        assert not run('ip', '-o', 'addr', 'show', 'dev', dev, 'scope', 'global').strip()
        assert not run('ovs-vsctl', '--timeout=3', 'iface-to-br', dev, reject='no interface named')
        run('ip', 'link', 'set', dev, 'up')
    assert not run('tc', 'filter', 'show', 'dev', r0, 'ingress').strip()
    assert not any(q['kind'] in ('clsact', 'ingress') for q in json.loads(run('tc', '-j', 'qdisc', 'show', 'dev', r0)))
    run('ethtool', '-K', r0, 'hw-tc-offload', 'on')
    run('tc', 'qdisc', 'add', 'dev', r0, 'clsact')
    qdisc_owned = True
    run('ethtool', '-K', uplink, 'hw-tc-offload', 'off')
    flower('add', 7, 'dst_ip', '192.0.2.2', reject='HW TC disabled')
    run('ethtool', '-K', uplink, 'hw-tc-offload', 'on')
    flower('add', 20, 'dst_ip', '192.0.2.0/24', 'ip_proto', 'udp', 'dst_port', '4242',
           'src_mac', '02:76:00:00:00:00/ff:ff:00:00:00:00')
    assert any(f.get('options', {}).get('in_hw') for f in
	       json.loads(run('tc', '-j', 'filter', 'show', 'dev', r0, 'ingress')))
    send(packet(), 20, 1)
    send(packet(dst='192.0.3.2'), 20, 0)
    send(packet(options=b'\x01\x01\x01\x01'), 20, 1)
    send(packet(fragment=0x2000), 20, 1)
    send(packet(fragment=1), 20, 0)
    send(packet(payload=b'\x00\x00'), 20, 0)
    send(packet(total=200), 20, 0)
    send(packet(version=6), 20, 0)
    send(dst_mac + mac + b'\x08\x00' + b'\x45' * 5, 20, 0)
    before_drops = json.loads((debug / 'stats').read_text())['drop_packets']
    try:
        run('ip', 'link', 'set', uplink, 'vf', '1', 'state', 'disable')
        send(packet(), 20, 1)
        assert json.loads((debug / 'stats').read_text())['drop_packets'] == before_drops + 1
    finally:
        run('ip', 'link', 'set', uplink, 'vf', '1', 'state', 'auto')
    flower('add', 8, 'dst_ip', '203.0.113.200', 'ip_flags', 'nofrag', action=['gact', 'drop'])
    send(packet(dst='203.0.113.200'), 8, 1)
    send(packet(dst='203.0.113.200', fragment=0x2000), 8, 0)
    flower('add', 9, 'dst_ip', '203.0.113.201', 'num_of_vlans', '0', action=['gact', 'drop'])
    send(packet(dst='203.0.113.201'), 9, 1)
    flower('add', 10, 'src_ip', '198.51.100.1', action=['gact', 'drop'])
    send(packet(src='198.51.100.1'), 10, 1)
    assert json.loads((debug / 'stats').read_text())['drop_packets'] >= 1
    # Replacing a filter creates a new flower cookie in this pinned TC core.
    flower('replace', 20, 'dst_ip', '192.0.2.0/24', 'ip_proto', 'udp', 'dst_port', '4242',
           'src_mac', '02:76:00:00:00:00/ff:ff:00:00:00:00')
    assert len(flows()) == 4
    send(packet(), 20, 1)
    flower('replace', 20, 'dst_ip', '192.0.2.0/24', 'ip_proto', 'udp', 'dst_port', '4242',
           'src_mac', '02:76:00:00:00:00/ff:ff:00:00:00:00',
           action=['mirred', 'egress', 'mirror', 'dev', r1], reject='Unsupported action ID')
    assert len(flows()) == 4
    send(packet(), 20, 1)
    flower('add', 30, 'ip_proto', 'icmp', 'type', '8', 'code', '0')
    send(packet(proto=1, payload=bytes.fromhex('0800000012340001')), 30, 1)
    send(packet(proto=1, payload=bytes.fromhex('0000000012340001')), 30, 0)
    flower('add', 31, 'ip_proto', 'tcp', 'tcp_flags', '0x002/0x012')
    tcp = struct.pack('!HHIIHHHH', 1234, 80, 0, 0, 0x5002, 1024, 0, 0)
    send(packet(proto=6, payload=tcp), 31, 1)
    send(packet(proto=6, payload=tcp[:4]), 31, 0)
    flower('add', 40, 'src_ip', '192.0.2.1', chain=1, reject='Only chain zero')
    flower('add', 41, 'dst_ip', '192.0.2.2', action=['mirred', 'egress', 'redirect', 'dev', v1], reject='Redirect must target')
    flower('add', 42, 'dst_ip', '192.0.2.2', action=['vlan', 'push', 'id', '100'], reject='Unsupported action ID')
    flower('add', 43, 'dst_ip', '192.0.2.2', action=['mirred', 'egress', 'redirect', 'dev', r1, 'hw_stats', 'immediate'], reject='does not support selected HW stats')
    flower('add', 44, 'dst_ip', '192.0.2.2', action=['gact', 'drop', 'action', 'gact', 'drop'], reject='Exactly one terminal')
    run('tc', 'filter', 'add', 'dev', r0, 'ingress', 'protocol', 'ipv6', 'pref', '45',
        'flower', 'skip_sw', 'dst_ip', '2001:db8::1', 'action', 'gact', 'drop', reject='IPV6_ADDRS')
    run('tc', 'filter', 'add', 'dev', r0, 'ingress', 'protocol', 'arp', 'pref', '46',
        'flower', 'skip_sw', 'arp_sip', '192.0.2.1', 'action', 'gact', 'drop', reject='ARP mask')
    flower('add', 20, 'dst_ip', '192.0.2.2', 'ip_proto', 'udp', 'dst_port', '4242',
           handle=200, reject='ambiguous')
    snapshots = []
    for _ in range(3):
        snapshots.append(json.loads(run('tc', '-s', '-j', 'filter', 'show', 'dev', r0, 'ingress')))
    def counts(dump):
        return [a['stats']['packets'] for f in dump for a in f.get('options', {}).get('actions', [])]
    assert counts(snapshots[0]) == counts(snapshots[1]) == counts(snapshots[2]), snapshots
    run('ethtool', '-K', r0, 'hw-tc-offload', 'off', reject='Could not change any device features')
    run('ethtool', '-K', uplink, 'hw-tc-offload', 'off', reject='Could not change any device features')
    # Capacity is measured using actual TC-owned entries, not a fake allocation flag.
    initial = len(flows())
    for index in range(256 - initial):
        flower('add', 100 + index, 'dst_ip', str(ipaddress.IPv4Address('203.0.113.0') + index), action=['gact', 'drop'])
    assert len(flows()) == 256
    flower('add', 500, 'dst_ip', '203.0.114.1', action=['gact', 'drop'], reject='capacity (256) exhausted')
    run('tc', 'qdisc', 'del', 'dev', r0, 'clsact')
    qdisc_owned = False
    assert not flows()
    run('ethtool', '-K', uplink, 'hw-tc-offload', 'on')
    # A rejected feature change leaves native wanted_features=requested off.
    # Restore that requested state before making a fresh off request.
    run('ethtool', '-K', r0, 'hw-tc-offload', 'on')
    run('ethtool', '-K', r0, 'hw-tc-offload', 'off')
    assert 'hw-tc-offload: off' in run('ethtool', '-k', r0)
    run('ethtool', '-K', r0, 'hw-tc-offload', 'on')
    print('PASS: real flower normalization, rejection, priority, replacement, stats and ENOSPC.', flush=True)
finally:
    if qdisc_owned:
        run('tc', 'qdisc', 'del', 'dev', r0, 'clsact')
    for dev in (v0, v1):
        run('ip', 'link', 'set', dev, 'down')
