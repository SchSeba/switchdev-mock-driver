#!/usr/bin/env python3
"""Real TC/RCU/debugfs lifetime stress after operator ownership is cleaned up."""
import errno
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time

bdf=sys.argv[1]; p=Path('/sys/bus/pci/devices')/bdf; debug=Path('/sys/kernel/debug/mock_smartnic')/bdf
assert (p/'driver').resolve().name=='mock_smartnic_pf'
assert (p/'sriov_numvfs').read_text().strip()=='2'
def run(*args, reject=False):
 r=subprocess.run(args,text=True,capture_output=True,timeout=20)
 assert (r.returncode!=0 if reject else r.returncode==0),(args,r.stdout,r.stderr)
 return r.stdout
ports=json.loads(run('devlink','-j','port','show'))['port']
reps={v['vfnum']:v['netdev'] for k,v in ports.items() if k.startswith('pci/'+bdf+'/') and v.get('flavour')=='pcivf'}
r0,r1=reps[0],reps[1]
v0=next((p/'virtfn0'/'net').iterdir()).name;v1=next((p/'virtfn1'/'net').iterdir()).name
for dev in (r0,r1,v0,v1):
 assert not run('ip','-o','addr','show','dev',dev,'scope','global').strip()
 run('ovs-vsctl','--timeout=5','iface-to-br',dev,reject=True)
 run('ip','link','set','dev',dev,'up')
assert not any(x['kind'] in ('clsact','ingress') for x in json.loads(run('tc','-j','qdisc','show','dev',r0)))
run('ethtool','-K',r0,'hw-tc-offload','on')
uplink=next((p/'net').iterdir()).name;run('ethtool','-K',uplink,'hw-tc-offload','on')
mac=lambda dev:bytes.fromhex(Path('/sys/class/net',dev,'address').read_text().strip().replace(':',''))
def frame(seq):
 payload=b'mock-stress'+seq.to_bytes(8,'big'); udp=struct.pack('!HHHH',1111,4242,len(payload)+8,0)+payload
 ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(udp),1,0,64,17,0,ipaddress.ip_address('192.0.2.1').packed,ipaddress.ip_address('192.0.2.2').packed)
 total=sum(struct.unpack('!10H',ip))
 while total>>16: total=(total&65535)+(total>>16)
 ip=ip[:10]+struct.pack('!H',(~total)&65535)+ip[12:]
 return mac(v1)+mac(v0)+b'\x08\x00'+ip+udp
stop=threading.Event(); errors=[]; received=set(); sent=[0]; deadline=time.monotonic()+90
fd=os.open(debug/'stats',os.O_RDONLY)
def stats_reader():
 try:
  while not stop.is_set() and time.monotonic()<deadline:
   try:
    os.lseek(fd,0,os.SEEK_SET);d=json.loads(os.read(fd,65536))
    assert d['schema_version']==1 and 0<=d['active_flows']<=256
   except OSError as e:
    if e.errno in (errno.EIO,errno.ENODEV): return
    raise
   time.sleep(.001)
 except BaseException as e: errors.append(e)
def sender():
 try:
  with socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(0x0800)) as s:
   s.bind((v0,0))
   while not stop.is_set() and time.monotonic()<deadline:
    s.send(frame(sent[0]));sent[0]+=1;time.sleep(.001)
 except BaseException as e: errors.append(e)
def receiver():
 try:
  with socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(0x0800)) as s:
   s.bind((v1,0));s.settimeout(.05)
   while not stop.is_set() and time.monotonic()<deadline:
    try: data=s.recv(65535)
    except socket.timeout: continue
    if data[42:53]!=b'mock-stress': continue
    seq=int.from_bytes(data[53:61],'big')
    assert seq not in received,('duplicate RX',seq)
    received.add(seq)
 except BaseException as e: errors.append(e)
threads=[threading.Thread(target=f) for f in (stats_reader,sender,receiver)]
owned=False
try:
 run('tc','qdisc','add','dev',r0,'clsact');owned=True
 def rule(action):
  run('tc','filter','replace','dev',r0,'ingress','protocol','ip','pref','5','handle','5','flower','skip_sw','dst_ip','192.0.2.2','ip_proto','udp','action',*action)
 rule(['mirred','egress','redirect','dev',r1])
 for t in threads:t.start()
 for i in range(200):
  assert time.monotonic()<deadline
  rule(['gact','drop'] if i%2 else ['mirred','egress','redirect','dev',r1])
 assert received and sent[0]>100 and not errors,(sent,received,errors)
 run('tc','qdisc','del','dev',r0,'clsact');owned=False
 assert json.loads((debug/'stats').read_text())['active_flows']==0
 time.sleep(.2); n=len(received); time.sleep(.3)
 assert len(received)==n,'RX continued without offloaded rules or an OVS bridge'
 stop.set()
 for t in threads:t.join(5);assert not t.is_alive()
 assert not errors,errors
 print('PASS: 200 TC replace/drop/redirect operations under raw traffic and concurrent debugfs reads; no duplicate delivery or forwarding after deletion',flush=True)
 for cycle in range(10):
  (p/'sriov_numvfs').write_text('0\n')
  run('devlink','dev','eswitch','set','pci/'+bdf,'mode','legacy')
  (p/'sriov_numvfs').write_text('2\n')
  run('devlink','dev','eswitch','set','pci/'+bdf,'mode','switchdev')
  (p/'sriov_numvfs').write_text('0\n');(p/'sriov_numvfs').write_text('3\n')
  assert len(list(p.glob('virtfn*')))==3
  run('devlink','dev','eswitch','set','pci/'+bdf,'mode','legacy')
  (p/'sriov_numvfs').write_text('0\n')
  assert not list(p.glob('virtfn*'))
  print('PASS: VF/mode cycle',cycle+1,'2 -> 0 -> 3 -> 0; switchdev/legacy',flush=True)
 # Hold a real debugfs file across PF removal. It pins the module and PF allocation.
 stop.clear();deadline=time.monotonic()+30
 removal_reader=threading.Thread(target=stats_reader);removal_reader.start()
 with open('/sys/bus/pci/drivers/mock_smartnic_pf/unbind','w') as f:f.write(bdf+'\n')
 removal_reader.join(5);assert not removal_reader.is_alive() and not errors,errors
 try:
  os.lseek(fd,0,os.SEEK_SET);os.read(fd,65536)
 except OSError as e:assert e.errno in (errno.EIO,errno.ENODEV),e
 else:raise AssertionError('removed debugfs file still readable')
 run('modprobe','-r','mock_smartnic',reject=True)
 os.close(fd);fd=None
 run('modprobe','-r','mock_smartnic')
 assert not Path('/sys/module/mock_smartnic').exists()
 run('modprobe','mock_smartnic')
 assert (p/'driver').resolve().name=='mock_smartnic_pf'
 assert (p/'sriov_numvfs').read_text().strip()=='0'
 assert json.loads((debug/'stats').read_text())['eswitch_mode']=='legacy'
 print('PASS: open debugfs removal safety, module owner pin, clean unload/reload, exact PF rebind and zero VFs',flush=True)
finally:
 stop.set()
 for t in threads:
  if t.ident:t.join(5)
 if owned:run('tc','qdisc','del','dev',r0,'clsact')
 if fd is not None:os.close(fd)
