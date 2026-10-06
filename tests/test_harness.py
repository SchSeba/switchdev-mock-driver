#!/usr/bin/env python3
"""Local fixtures only: these do not exercise a kernel, VM, CNI or cluster."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("renderer",ROOT/"scripts/render.py")
renderer=importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

class RenderTests(unittest.TestCase):
    def documents(self, **extra):
        env={"PF_BDF":"0000:00:06.0","CLUSTER_TYPE":"kubernetes",**extra}
        with patch.dict(os.environ,env,clear=True):
            return renderer.build()
    def test_kubernetes_pool_is_scoped_without_name(self):
        doc=self.documents()["10-poolconfig.yaml"]
        self.assertIn("nodeSelector",doc["spec"])
        self.assertNotIn("name",doc["spec"]["ovsHardwareOffloadConfig"])
        self.assertEqual("true",doc["spec"]["ovsHardwareOffloadConfig"]["otherConfig"]["hw-offload"])
    def test_openshift_named_pool_has_no_node_selector(self):
        doc=self.documents(CLUSTER_TYPE="openshift",MCP_NAME="mock-smartnic")["10-poolconfig.yaml"]
        self.assertEqual("mock-smartnic",doc["spec"]["ovsHardwareOffloadConfig"]["name"])
        self.assertNotIn("nodeSelector",doc["spec"])
        self.assertNotIn("maxUnavailable",doc["spec"])
    def test_openshift_broad_pool_refused(self):
        with self.assertRaises(ValueError):
            self.documents(CLUSTER_TYPE="openshift",MCP_NAME="worker")
    def test_invalid_bdf_refused(self):
        with self.assertRaises(ValueError): self.documents(PF_BDF="../../etc")
    def test_policy_leaves_creation_to_operator(self):
        doc=self.documents()["20-nodepolicy.yaml"]["spec"]
        self.assertFalse(doc["externallyManaged"])
        self.assertEqual("switchdev",doc["eSwitchMode"])
        self.assertEqual({"ovs":{}},doc["bridge"])
    def test_network_no_default_route_or_explicit_bridge(self):
        doc=self.documents()["30-ovsnetwork.yaml"]
        self.assertEqual("OVSNetwork",doc["kind"])
        self.assertNotIn("bridge",doc["spec"])
        ipam=json.loads(doc["spec"]["ipam"])
        self.assertNotIn("routes",ipam); self.assertNotIn("gateway",ipam)
    def test_pods_have_resources_and_nonprivileged_udp(self):
        docs=self.documents()
        for suffix in ("a","b"):
            p=docs[f"40-pod-{suffix}.yaml"]
            self.assertNotIn("nodeName",p["spec"])
            c=p["spec"]["containers"][0]
            self.assertEqual("1",c["resources"]["requests"]["openshift.io/mock_smartnic"])
            self.assertEqual(["ALL"],c["securityContext"]["capabilities"]["drop"])
            self.assertFalse(c["securityContext"]["allowPrivilegeEscalation"])
    def test_yaml_roundtrip_if_parser_available(self):
        try: import yaml
        except ImportError: self.skipTest("PyYAML is optional for local validation")
        for doc in self.documents().values():
            self.assertEqual(doc,yaml.safe_load(renderer.yaml(doc)))

class EvidenceTests(unittest.TestCase):
    def fixture(self):
        flow=lambda n:{"schema_version":1,"flows":[
            {"cookie":"a","ingress_vf":0,"packets":n,"actions":[{"kind":"redirect","vf":1}]},
            {"cookie":"b","ingress_vf":1,"packets":n,"actions":[{"kind":"redirect","vf":0}]}]}
        return {
            "mapping.json":{"vfs":[{"pci":"0000:00:10.0","vf":0,"representor":"rep0"},
                                       {"pci":"0000:00:10.2","vf":1,"representor":"rep1"}]},
            "a-to-b.json":{"sent":10,"received":10},"b-to-a.json":{"sent":10,"received":10},
            "stats-before.json":{"schema_version":1,"offload_hits":2},
            "stats-after.json":{"schema_version":1,"offload_hits":20},
            "flows-before.json":flow(1),"flows-after.json":flow(10),
            "tc.json":{str(v):{"filters":[{"options":{"in_hw":True}}]} for v in (0,1)},
            "ovs.txt":'HWOL="true"\nrep0 rep1 packets:20\n'}
    def verify(self, data):
        with tempfile.TemporaryDirectory() as d:
            for name,content in data.items():
                Path(d,name).write_text(content if isinstance(content,str) else json.dumps(content))
            return subprocess.run([sys.executable,str(ROOT/"scripts/verify-evidence.py"),d,
                "0000:00:10.0","0000:00:10.2"],capture_output=True,text=True)
    def test_complete_synthetic_evidence_passes(self):
        result=self.verify(self.fixture()); self.assertEqual(0,result.returncode,result.stderr)
    def test_connectivity_without_driver_hits_fails(self):
        data=self.fixture();data["stats-after.json"]["offload_hits"]=2
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_stale_directional_flows_fail(self):
        data=self.fixture();data["flows-after.json"]=data["flows-before.json"]
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_missing_in_hw_fails(self):
        data=self.fixture();data["tc.json"]["0"]["filters"][0]["options"]["in_hw"]=False
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_disabled_ovs_offload_fails(self):
        data=self.fixture();data["ovs.txt"]='HWOL="false"\nrep0 rep1 packets:20\n'
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_wrong_allocated_pci_fails(self):
        data=self.fixture();data["mapping.json"]["vfs"][0]["pci"]="0000:ff:00.0"
        self.assertNotEqual(0,self.verify(data).returncode)

if __name__=="__main__": unittest.main(verbosity=2)
