#!/usr/bin/env bash
# Inject a real, valid host-local IPAM exhaustion and recover through CNI retry.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
cluster_guard; mutation_guard
[[ $NUM_VFS == 2 ]] || die 'Requires the two-VF operator policy.'
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require dedicated PF acknowledgements.'
k -n "$OPERATOR_NAMESPACE" get sriovnetworknodepolicy "$POLICY_NAME" -o json | jq -e --arg p "$PF_BDF" --arg r "$RESOURCE_NAME" '
 .metadata.labels["app.kubernetes.io/part-of"]=="mock-smartnic-lab" and .spec.nicSelector.rootDevices==[$p] and .spec.resourceName==$r and .spec.numVfs==2' >/dev/null
[[ $(k -n "$WORKLOAD_NAMESPACE" get pods -l app.kubernetes.io/part-of=mock-smartnic-lab -o json | jq '.items|length') == 0 ]] || die 'Finish/delete the pod-cycle workloads first.'
A="$ROOT/artifacts/allocation-recovery"; mkdir -p "$A"
network=$NETWORK_NAME-allocation-test
[[ $(k -n "$OPERATOR_NAMESPACE" get ovsnetwork "$network" --ignore-not-found -o name) == '' ]] || die 'Test network already exists.'
for name in mock-alloc-a mock-alloc-b; do
 [[ $(k -n "$WORKLOAD_NAMESPACE" get pod "$name" --ignore-not-found -o name) == '' ]] || die 'Test pod already exists.'
done
python3 - "$ROOT" "$A" "$network" <<'PY'
import importlib.util,json,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('render',Path(sys.argv[1])/'scripts/render.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);d=m.build()
n=d['30-ovsnetwork.yaml'];n['metadata']['name']=sys.argv[3]
n['spec']['ipam']=json.dumps({'type':'host-local','subnet':'198.20.0.0/24','rangeStart':'198.20.0.10','rangeEnd':'198.20.0.10'})
Path(sys.argv[2],'network.json').write_text(json.dumps(n))
for suffix in ('a','b'):
 p=d['40-pod-'+suffix+'.yaml'];p['metadata']['name']='mock-alloc-'+suffix
 net=json.loads(p['metadata']['annotations']['k8s.v1.cni.cncf.io/networks']);net[0]['name']=sys.argv[3]
 p['metadata']['annotations']['k8s.v1.cni.cncf.io/networks']=json.dumps(net)
 Path(sys.argv[2],'pod-'+suffix+'.json').write_text(json.dumps(p))
PY
k apply -f "$A/network.json"
end=$((SECONDS+90))
until k -n "$WORKLOAD_NAMESPACE" get network-attachment-definition "$network" -o json > "$A/nad.json" 2>/dev/null; do
 ((SECONDS<end)) || die 'Network controller did not generate the negative-test NAD.';sleep 2
done
k apply -f "$A/pod-a.json"
k -n "$WORKLOAD_NAMESPACE" wait pod/mock-alloc-a --for=condition=Ready --timeout=120s
k apply -f "$A/pod-b.json"
uid=$(k -n "$WORKLOAD_NAMESPACE" get pod mock-alloc-b -o json | jq -r '.metadata.uid')
end=$((SECONDS+120))
while :; do
 k -n "$WORKLOAD_NAMESPACE" get events -o json > "$A/events.json"
 if jq -e --arg u "$uid" 'any(.items[]; .involvedObject.uid==$u and (.message|ascii_downcase|contains("no ip addresses available")))' "$A/events.json" >/dev/null; then break; fi
 ((SECONDS<end)) || die 'Expected IPAM exhaustion was not observed.';sleep 2
done
k -n "$WORKLOAD_NAMESPACE" get pod mock-alloc-b -o json > "$A/exhausted.json"
jq -e --arg node "$NODE_NAME" '.spec.nodeName==$node and .status.phase=="Pending"' "$A/exhausted.json" >/dev/null
k -n "$WORKLOAD_NAMESPACE" delete pod mock-alloc-a --wait=true --timeout=120s
k -n "$WORKLOAD_NAMESPACE" wait pod/mock-alloc-b --for=condition=Ready --timeout=150s
k -n "$WORKLOAD_NAMESPACE" get pod mock-alloc-b -o json > "$A/recovered.json"
jq -e '.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson|any(.[]; .interface=="net1" and .ips==["198.20.0.10"])' "$A/recovered.json" >/dev/null
pci=$(jq -r '.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson|.[]|select(.interface=="net1")|.["device-info"].pci["pci-address"]' "$A/recovered.json")
[[ $pci =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]$ ]] || die 'Invalid recovered allocation identity.'
[[ $(remote readlink -f "/sys/bus/pci/devices/$pci/physfn") == /sys/devices/*/"$PF_BDF" ]] || die 'Recovered VF belongs to another PF.'
k -n "$WORKLOAD_NAMESPACE" delete pod mock-alloc-b --wait=true --timeout=120s
k -n "$OPERATOR_NAMESPACE" delete ovsnetwork "$network" --wait=true --timeout=120s
k -n "$WORKLOAD_NAMESPACE" wait network-attachment-definition/"$network" --for=delete --timeout=90s
printf '{"passed":true,"failure":"host-local IPAM exhaustion","recovery":"same pod becomes Ready after address release"}\n' > "$A/verdict.json"
echo 'PASS: actual failed sandbox allocation, clear IPAM error, address release and CNI retry recovery; test network/pods cleaned.'
