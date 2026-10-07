"""Local safety checks; fixtures never substitute for real PCI/runtime evidence."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WorkerSetupTests(unittest.TestCase):
    def test_kernel_defaults_to_running_release(self):
        source = (ROOT/'scripts/setup-worker.sh').read_text().split(
            '[[ $EMULATED_PF_ACK == YES', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            uname = Path(directory)/'uname'
            uname.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_KERNEL"\n')
            uname.chmod(0o755)
            for release in ('5.14.0-754.el9.x86_64', '6.12.0-lab', '7.0.11-200.fc44.x86_64'):
                result = subprocess.run(
                    ['bash', '-c', source+'\nprintf "%s\\n" "$KERNEL_RELEASE"',
                     str(ROOT/'scripts/setup-worker.sh'), '--pf', '0000:29:00.0', '--emulated-pf'],
                    env={**os.environ, 'PATH':directory+':'+os.environ['PATH'], 'TEST_KERNEL':release},
                    text=True, capture_output=True)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(release, result.stdout.strip())

    def test_invalid_cli_refused_before_install(self):
        for args in ([], ['--pf'], ['--unknown'],
                     ['--pf', '0000:29:20.0', '--kernel', 'bad', '--emulated-pf'],
                     ['--pf', '0000:29:00.0', '--kernel', 'bad', '--emulated-pf'],
                     ['--pf', '0000:29:00.0', '--kernel', os.uname().release]):
            with self.subTest(args=args):
                result = subprocess.run([str(ROOT/'scripts/setup-worker.sh'), *args],
                                        text=True, capture_output=True)
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn('Ready:', result.stdout)

    def test_native_vf_coexistence_uses_mock_first_load_order(self):
        script = (ROOT/'scripts/guest.sh').read_text()
        self.assertIn('softdep igbvf pre: mock_smartnic', script)
        self.assertNotIn('blacklist igbvf', script)
        self.assertNotIn('install igbvf /bin/false', script)
        boot = script.split("<<'BOOT'\n", 1)[1].split('\nBOOT', 1)[0]
        self.assertLess(boot.index('modinfo -F vermagic mock_smartnic'),
                        boot.index('modprobe mock_smartnic'))
        self.assertNotIn('[[ ! -e /sys/module/igbvf ]]', boot)
        self.assertLess(boot.index('not_used "${names[0]}" boot'),
                        boot.index('modprobe mock_smartnic'))
        self.assertLess(boot.index('/sys/bus/pci/drivers/mock_smartnic_pf/bind'),
                        boot.rindex('modprobe igbvf'))
        persist = script.split('  persist)', 1)[1].split('  unpersist)', 1)[0]
        self.assertLess(persist.index('depmod -a'), persist.rindex('modprobe igbvf'))
        self.assertIn("fail 'Other native igbvf devices are bound.'", script)

    def test_boot_refuses_a_mismatched_module_before_binding(self):
        guard = next(line for line in (ROOT/'scripts/guest.sh').read_text().splitlines()
                     if line.startswith('[[ $(modinfo -F vermagic mock_smartnic)'))
        for vermagic, passed in (('6.12.0-lab SMP mod_unload', True),
                                 ('6.12.0-lab-old SMP mod_unload', False),
                                 ('5.14.0-427.el9.x86_64 SMP mod_unload', False),
                                 ('', False)):
            result = subprocess.run(
                ['bash', '-c', 'set -e; uname() { echo 6.12.0-lab; }; '
                 'modinfo() { printf "%s\\n" "$TEST_VERMAGIC"; }; '
                 'fail() { exit 1; }; '+guard+'; echo SAFE'],
                env={**os.environ, 'TEST_VERMAGIC':vermagic}, text=True, capture_output=True)
            self.assertEqual(passed, result.returncode == 0, result.stderr)
            self.assertEqual(passed, 'SAFE' in result.stdout)

    def test_boot_brings_up_only_the_selected_pf_uplink(self):
        boot = (ROOT/'scripts/guest.sh').read_text().split("<<'BOOT'\n", 1)[1].split('\nBOOT', 1)[0]
        self.assertNotIn('exit 0', boot)
        uplink = 'mapfile -t names' + boot.rsplit('mapfile -t names', 1)[1]
        with tempfile.TemporaryDirectory() as directory:
            net = Path(directory)/'net'
            net.mkdir()
            for count in (0, 1, 2):
                if count:
                    (net/f'uplink{count}').mkdir()
                result = subprocess.run(
                    ['bash', '-c', 'set -e; P=$1; fail() { exit 1; }; '
                     'ip() { printf "%s\\n" "$*"; }; '+uplink, 'test', directory],
                    text=True, capture_output=True)
                self.assertEqual(count == 1, result.returncode == 0, result.stderr)
                self.assertEqual('link set dev uplink1 up' if count == 1 else '',
                                 result.stdout.strip())

    def test_primary_and_ownership_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            net = root/'net'/'eth0'
            net.mkdir(parents=True)
            # Redirect sysfs paths only in this test copy, never in production.
            guard = root/'guard.sh'
            guard.write_text((ROOT/'scripts/lib/pf-guard.sh').read_text()
                             .replace('/sys/class/net', str(root/'net')))
            ip = root/'ip'
            ip.write_text('''#!/usr/bin/env bash
case "$*" in
  '-o addr show dev eth0 scope global')
    [[ $SCENARIO != error ]] || exit 1
    [[ $SCENARIO != address ]] || echo 'inet 192.0.2.1/24'
    ;;
  'route show default dev eth0') [[ $SCENARIO != route ]] || echo 'default dev eth0' ;;
  '-6 route show default dev eth0') [[ $SCENARIO != route6 ]] || echo 'default dev eth0' ;;
  'route get 192.0.2.2')
    [[ $SCENARIO != peer ]] && echo '192.0.2.2 dev eth1 src 192.0.2.1' || echo '192.0.2.2 dev eth0 src 192.0.2.1'
    ;;
esac
exit 0
''')
            ovs = root/'ovs-vsctl'
            ovs.write_text('''#!/usr/bin/env bash
[[ $SCENARIO != ovsdown ]] || exit 1
[[ $SCENARIO != ovs || "$*" != *iface-to-br* ]] || echo br-owned
exit 0
''')
            ip.chmod(0o755); ovs.chmod(0o755)
            for case in ('idle', 'address', 'route', 'route6', 'peer', 'ovs', 'ovsdown', 'error', 'master', 'upper'):
                with self.subTest(case=case):
                    link = net/('master' if case == 'master' else 'upper_vlan')
                    if case in ('master', 'upper'): link.symlink_to(root)
                    result = subprocess.run(
                        ['bash', '-c', 'set -Eeuo pipefail; fail() { echo "$*" >&2; exit 1; }; '
                         'SSH_PEER=192.0.2.2; source "$1"; not_used eth0; echo SAFE', 'test', str(guard)],
                        env={**os.environ, 'PATH':str(root)+':'+os.environ['PATH'], 'SCENARIO':case},
                        text=True, capture_output=True)
                    if case in ('master', 'upper'): link.unlink()
                    self.assertEqual(case == 'idle', result.returncode == 0, result.stderr)
                    self.assertEqual(case == 'idle', 'SAFE' in result.stdout)

if __name__ == '__main__':
    unittest.main()
