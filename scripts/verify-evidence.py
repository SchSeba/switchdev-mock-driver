#!/usr/bin/env python3
"""Reject connectivity-only and stale/unrelated offload evidence."""
import json
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
pa, pb = sys.argv[2:4]
def load(name):
    return json.loads((p/name).read_text())
def require(ok, msg):
    if not ok:
        raise SystemExit("FAIL: " + msg)

mapping = {v["pci"]: v for v in load("mapping.json")["vfs"]}
require(pa in mapping and pb in mapping, "Allocated VFs do not belong to the selected mock PF")
a, b = mapping[pa]["vf"], mapping[pb]["vf"]
require(a != b, "Pods allocated the same VF")
for n in ("a-to-b.json", "b-to-a.json"):
    result = load(n)
    require(result["received"] == result["sent"] > 0, "UDP loss or mismatched payloads")
for n in ("ping-a-to-b.json", "ping-b-to-a.json"):
    result = load(n)
    require(result.get("protocol") == "icmp" and result["received"] == result["sent"] > 0,
            "ICMP loss or missing ping evidence")
before, after = load("stats-before.json"), load("stats-after.json")
require(after.get("schema_version") == 1, "Unexpected debugfs stats schema")
require(after["offload_hits"] > before["offload_hits"], "No new simulator offload hits")
f0, f1 = load("flows-before.json"), load("flows-after.json")
require(f0.get("schema_version") == f1.get("schema_version") == 1, "Unexpected flow evidence schema")
def packets(doc, source, dest):
    return sum(f["packets"] for f in doc["flows"] if f["ingress_vf"] == source
               and any(x.get("kind")=="redirect" and x.get("vf")==dest for x in f["actions"]))
for source,dest in ((a,b),(b,a)):
    require(packets(f1,source,dest)>packets(f0,source,dest), f"No new directional flow hits VF{source}->VF{dest}")
tc=load("tc.json")
for v in (a,b):
    require(str(v) in tc, f"No representor TC evidence for VF{v}")
    require(any(f.get("options",{}).get("in_hw") is True for f in tc[str(v)]["filters"]),
            f"No in_hw flower filter for VF{v}")
ovs=(p/"ovs.txt").read_text()
require(re.search(r'^HWOL="?true"?\s*$',ovs,re.M), "OVS hw-offload is not true")
for pci in (pa,pb):
    require(mapping[pci]["representor"] in ovs, "OVS evidence is missing a selected representor")
require("packets:" in ovs, "No OVS offloaded datapath flow with packet accounting")
print("PASS: distinct allocated PCI VFs, net1 ICMP/UDP, TC in_hw, OVS offload, and new driver hits in both directions")
