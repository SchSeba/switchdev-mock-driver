#!/usr/bin/env python3
"""Render Kubernetes YAML using only the Python standard library.

Every string is JSON-quoted, which is valid YAML. No shell/eval or arbitrary YAML
loader is used. kubectl server-side dry-run is still required against the target.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def value(key: str, default: str = "") -> str:
    result = os.environ.get(key, default)
    if not result:
        raise ValueError(f"Set {key} in config/lab.env")
    return result

def scalar(x: object) -> str:
    return json.dumps(x, ensure_ascii=False)

def yaml(x: object, level: int = 0) -> str:
    pad = " " * level
    if isinstance(x, dict):
        if not x:
            return pad + "{}\n"
        out = ""
        for key, val in x.items():
            out += pad + scalar(key) + ":"
            if isinstance(val, (dict, list)) and val:
                out += "\n" + yaml(val, level + 2)
            else:
                out += " " + scalar(val) + "\n"
        return out
    if isinstance(x, list):
        out = ""
        for val in x:
            if isinstance(val, (dict, list)) and val:
                out += pad + "-\n" + yaml(val, level + 2)
            else:
                out += pad + "- " + scalar(val) + "\n"
        return out
    return pad + scalar(x) + "\n"

def build() -> dict[str, dict]:
    ns = value("OPERATOR_NAMESPACE", "sriov-network-operator")
    wns = value("WORKLOAD_NAMESPACE", "mock-sriov-e2e")
    resource = value("RESOURCE_NAME", "mock_smartnic")
    prefix = value("RESOURCE_PREFIX", "openshift.io")
    policy = value("POLICY_NAME", "mock-smartnic-switchdev")
    network = value("NETWORK_NAME", "mock-ovs")
    pool = value("POOL_NAME", "mock-smartnic-pool")
    bdf = value("PF_BDF")
    count = int(value("NUM_VFS", "2"))
    platform = value("CLUSTER_TYPE", "kubernetes")
    image = value("WORKLOAD_IMAGE", "python:3.12-slim")
    if platform not in {"kubernetes", "openshift"}:
        raise ValueError("CLUSTER_TYPE must be kubernetes or openshift")
    if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", bdf):
        raise ValueError("PF_BDF must be a lower-case, full-domain PCI BDF")
    if not 2 <= count <= 7:
        raise ValueError("The initial igb laboratory contract supports 2..7 VFs")
    for key in (ns, wns, policy, network, pool):
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", key):
            raise ValueError(f"Invalid lab object name: {key}")
    if not re.fullmatch(r"[A-Za-z0-9_]+", resource):
        raise ValueError("Invalid SR-IOV resourceName")
    if not re.fullmatch(r"[a-z0-9.-]+", prefix):
        raise ValueError("Invalid resource prefix")
    labels = {"mock-smartnic.test/target": "dut"}
    api = "sriovnetwork.openshift.io/v1"
    def obj(kind: str, name: str, spec: dict) -> dict:
        return {"apiVersion": api, "kind": kind, "metadata": {"name": name, "namespace": ns,
                "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"}}, "spec": spec}
    poolspec: dict = {"ovsHardwareOffloadConfig": {"otherConfig": {"hw-offload": "true", "tc-policy": "none"}}}
    if platform == "kubernetes":
        # At the pinned revision, named HWOL objects are skipped by findNodePoolConfig.
        # Leave name absent so this scoped pool feeds NodeState.spec.system.ovsConfig.
        poolspec["nodeSelector"] = {"matchLabels": labels}
        poolspec["maxUnavailable"] = 1
    else:
        mcp = value("MCP_NAME")
        if mcp in {"master", "worker"}:
            raise ValueError("Use an existing dedicated OpenShift MachineConfigPool, not master/worker")
        poolspec["ovsHardwareOffloadConfig"]["name"] = mcp
        # Do not combine this with nodeSelector/maxUnavailable: upstream webhook rejects it.
    files = {
        "00-namespace.yaml": {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": wns,
            "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"}}},
        "10-poolconfig.yaml": obj("SriovNetworkPoolConfig", pool, poolspec),
        "20-nodepolicy.yaml": obj("SriovNetworkNodePolicy", policy, {
            "resourceName": resource, "nodeSelector": labels, "priority": 10,
            "numVfs": count, "nicSelector": {"rootDevices": [bdf]},
            "deviceType": "netdevice", "isRdma": False, "linkType": "eth",
            "eSwitchMode": "switchdev", "mtu": 1500, "externallyManaged": False,
            "bridge": {"ovs": {}}}),
        "30-ovsnetwork.yaml": obj("OVSNetwork", network, {
            "networkNamespace": wns, "resourceName": resource,
            "ipam": json.dumps({"type": "host-local", "subnet": "198.19.0.0/24",
                    "rangeStart": "198.19.0.10", "rangeEnd": "198.19.0.50"})})}
    echo = "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
    for suffix in ("a", "b"):
        security: dict = {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]},
                          "runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}}
        if platform == "kubernetes":
            security["runAsUser"] = 10000
            security["runAsGroup"] = 10000
        files[f"40-pod-{suffix}.yaml"] = {
            "apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": f"mock-ovs-{suffix}", "namespace": wns,
                "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"},
                "annotations": {"k8s.v1.cni.cncf.io/networks": json.dumps([
                    {"name": network, "namespace": wns, "interface": "net1"}])}},
            "spec": {"nodeSelector": labels, "terminationGracePeriodSeconds": 5,
                "containers": [{"name": "echo", "image": image, "imagePullPolicy": "IfNotPresent",
                    "command": ["python3", "-u", "-c", echo], "securityContext": security,
                    "resources": {"requests": {f"{prefix}/{resource}": "1", "cpu": "50m", "memory": "32Mi"},
                                  "limits": {f"{prefix}/{resource}": "1", "memory": "128Mi"}}}]}}
    return files

def main() -> None:
    dest = ROOT / "rendered"
    dest.mkdir(exist_ok=True)
    for filename, doc in build().items():
        (dest / filename).write_text("# Generated by scripts/render.py; verify with server-side dry-run.\n" + yaml(doc))
    patch = {"spec": {"featureGates": {"manageSoftwareBridges": True}}}
    (dest / "05-operatorconfig-patch.json").write_text(json.dumps(patch, indent=2) + "\n")
    print(dest)

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
