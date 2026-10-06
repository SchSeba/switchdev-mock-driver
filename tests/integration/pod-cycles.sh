#!/usr/bin/env bash
# Real scheduler exhaustion/recovery and repeated ovs-cni ADD/DEL on the DUT.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
cluster_guard; mutation_guard
cycles=${1:-50}
[[ $cycles =~ ^[0-9]+$ ]] && ((cycles>=1 && cycles<=50)) || die 'Use 1..50 cycles.'
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require dedicated PF acknowledgements.'
A="$ROOT/artifacts/pod-cycles"
mkdir -p "$A"
k -n "$OPERATOR_NAMESPACE" get sriovnetworknodepolicy "$POLICY_NAME" -o json | jq -e --arg p "$PF_BDF" '
 .metadata.labels["app.kubernetes.io/part-of"]=="mock-smartnic-lab" and .spec.nicSelector.rootDevices==[$p] and .spec.numVfs==2' >/dev/null
[[ $NUM_VFS == 2 ]] || die 'Exhaustion test requires exactly two VFs.'
for pod in mock-ovs-a mock-ovs-b mock-ovs-c; do
 if k -n "$WORKLOAD_NAMESPACE" get pod "$pod" -o json > "$A/check-owned.json" 2>/dev/null; then
  jq -e '.metadata.labels["app.kubernetes.io/part-of"]=="mock-smartnic-lab"' "$A/check-owned.json" >/dev/null || die 'Unowned test pod exists.'
 fi
done
[[ $(k -n "$WORKLOAD_NAMESPACE" get pod mock-ovs-c --ignore-not-found -o name) == '' ]] || die 'Third test pod already exists.'
python3 - "$ROOT" "$A" <<'PY'
import importlib.util,json,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('render',Path(sys.argv[1])/'scripts/render.py'); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
p=m.build()['40-pod-a.yaml'];p['metadata']['name']='mock-ovs-c'
Path(sys.argv[2],'third-pod.json').write_text(json.dumps(p)+'\n')
PY
ip_for() { k -n "$WORKLOAD_NAMESPACE" get pod "$1" -o json | jq -er '.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson|.[]|select(.interface=="net1")|.ips[]|select(contains(":")|not)'; }
ping_pair() {
 local a=$1 b=$2 ia ib
 ia=$(ip_for "$a"); ib=$(ip_for "$b")
 k -n "$WORKLOAD_NAMESPACE" exec -i "$a" -- python3 - "$ia" "$ib" --count 5 < "$ROOT/scripts/ping-probe.py"
 k -n "$WORKLOAD_NAMESPACE" exec -i "$b" -- python3 - "$ib" "$ia" --count 5 < "$ROOT/scripts/ping-probe.py"
}
clean_host() {
 remote sudo -n python3 - "$PF_BDF" <<'PY'
import json, pathlib, subprocess,sys,time
bdf=sys.argv[1];p=pathlib.Path('/sys/bus/pci/devices')/bdf; end=time.monotonic()+45
while True:
 ports=json.loads(subprocess.check_output(['devlink','-j','port','show']))['port']
 reps=[v['netdev'] for k,v in ports.items() if k.startswith('pci/'+bdf+'/') and v.get('flavour')=='pcivf']
 vfs=list(p.glob('virtfn*'))
 good=len(reps)==len(vfs)==2 and all(len(list((v/'net').iterdir()))==1 for v in vfs)
 good=good and all(subprocess.run(['ovs-vsctl','--timeout=5','port-to-br',r],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0 for r in reps)
 stats=json.loads((pathlib.Path('/sys/kernel/debug/mock_smartnic')/bdf/'stats').read_text())
 if good and stats['active_flows']==0:
  print(json.dumps({'clean':True,'offload_hits':stats['offload_hits'],'representors':reps}));break
 if time.monotonic()>=end: raise SystemExit('CNI DEL left an endpoint/representor/flow')
 time.sleep(1)
PY
}
# A third VF consumer must remain unscheduled, then recover when A releases a VF.
k -n "$WORKLOAD_NAMESPACE" wait pod/mock-ovs-a pod/mock-ovs-b --for=condition=Ready --timeout=120s
k apply -f "$A/third-pod.json"
end=$((SECONDS+90))
until k -n "$WORKLOAD_NAMESPACE" get pod mock-ovs-c -o json | jq -e --arg r "$RESOURCE_PREFIX/$RESOURCE_NAME" '
 (.spec.nodeName==null) and any(.status.conditions[]?; .type=="PodScheduled" and .status=="False" and (.message|contains("Insufficient "+$r)))' >/dev/null; do
 ((SECONDS<end)) || die 'Third pod did not report exhausted VF resources.'; sleep 2
done
k -n "$WORKLOAD_NAMESPACE" get pod mock-ovs-c -o json > "$A/exhausted.json"
k -n "$WORKLOAD_NAMESPACE" delete pod mock-ovs-a --wait=true --timeout=120s
k -n "$WORKLOAD_NAMESPACE" wait pod/mock-ovs-c --for=condition=Ready --timeout=120s
ping_pair mock-ovs-c mock-ovs-b
k -n "$WORKLOAD_NAMESPACE" get pod mock-ovs-c -o json > "$A/recovered.json"
k -n "$WORKLOAD_NAMESPACE" delete pod mock-ovs-b mock-ovs-c --wait=true --timeout=120s
clean_host > "$A/baseline.json"
previous=$(jq -r .offload_hits "$A/baseline.json")
for ((cycle=1;cycle<=cycles;cycle++)); do
 k apply -f "$ROOT/rendered/40-pod-a.yaml" -f "$ROOT/rendered/40-pod-b.yaml"
 k -n "$WORKLOAD_NAMESPACE" wait pod/mock-ovs-a pod/mock-ovs-b --for=condition=Ready --timeout=120s
 k -n "$WORKLOAD_NAMESPACE" get pod mock-ovs-a mock-ovs-b -o json > "$A/pods-$cycle.json"
 python3 - "$A/pods-$cycle.json" "$ROOT/artifacts/k08-passed/mapping.json" "$NODE_NAME" <<'PY'
import json,sys
pods=json.load(open(sys.argv[1]))['items'];mapping=json.load(open(sys.argv[2]))['vfs']; allowed={v['pci'] for v in mapping}; allocated=[]
for p in pods:
 assert p['spec']['nodeName']==sys.argv[3]
 n=next(n for n in json.loads(p['metadata']['annotations']['k8s.v1.cni.cncf.io/network-status']) if n.get('interface')=='net1')
 allocated.append(n['device-info']['pci']['pci-address'])
assert len(set(allocated))==2 and set(allocated)==allowed,allocated
PY
 ping_pair mock-ovs-a mock-ovs-b
 k -n "$WORKLOAD_NAMESPACE" delete pod mock-ovs-a mock-ovs-b --wait=true --timeout=120s
 clean_host > "$A/host-$cycle.json"
 hits=$(jq -r .offload_hits "$A/host-$cycle.json")
 ((hits>previous)) || die "Cycle $cycle passed ping without new driver offload hits."
 previous=$hits
 printf 'PASS: pod cycle %d/%d; exact VFs, 5/5 ICMP both ways, new offload hits=%d, clean CNI DEL\n' "$cycle" "$cycles" "$hits"
done
printf '{"passed":true,"cycles":%d,"resource_exhaustion_recovery":true,"final_pods":0}\n' "$cycles" > "$A/verdict.json"
