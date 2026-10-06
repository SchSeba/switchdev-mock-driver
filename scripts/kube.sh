#!/usr/bin/env bash
# Existing-cluster integration. Installation is a separate, explicit operation.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need python3
ACTION=${1:-preflight}
if [[ $ACTION == render ]]; then python3 "$ROOT/scripts/render.py"; exit; fi
cluster_guard
A="$ROOT/artifacts/kubernetes"
mkdir -p "$A"
OWN=mock-smartnic-lab
ensure_owned() {
  local kind=$1 name=$2 ns=$3 owner
  if k -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    owner=$(k -n "$ns" get "$kind" "$name" -o json | jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""')
    [[ $owner == "$OWN" ]] || die "Refuse to overwrite unowned $kind/$name in $ns"
  fi
}
preflight() {
  local machine vm others
  machine=$(k get node "$NODE_NAME" -o json | jq -r '.status.nodeInfo.machineID' | tr -d '-')
  vm=$(remote cat /etc/machine-id | tr -d '\r\n-')
  [[ -n $vm && $machine == "$vm" ]] || die 'SSH VM and selected Kubernetes node have different machine IDs.'
  others=$(k get nodes -l mock-smartnic.test/target=dut -o json | jq -r --arg n "$NODE_NAME" '.items[]|select(.metadata.name!=$n)|.metadata.name')
  [[ -z $others ]] || die "More than one DUT-labelled node: $others"
  k get crd sriovnetworknodepolicies.sriovnetwork.openshift.io \
    sriovnetworkpoolconfigs.sriovnetwork.openshift.io ovsnetworks.sriovnetwork.openshift.io \
    network-attachment-definitions.k8s.cni.cncf.io >/dev/null
  k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default >/dev/null
  k explain sriovnetworkpoolconfig.spec.ovsHardwareOffloadConfig.otherConfig >/dev/null
  k explain sriovnetworknodepolicy.spec.bridge.ovs >/dev/null
  k get node "$NODE_NAME" -o json > "$A/node-preflight.json"
  k -n "$OPERATOR_NAMESPACE" get sriovnetworknodepolicies,sriovnetworkpoolconfigs -o yaml > "$A/existing-policy-pools.yaml"
  k -n "$OPERATOR_NAMESPACE" get pods -o wide
  echo 'Inspect existing-policy-pools.yaml: no overlapping NIC policy or node-selected pool may include the DUT.'
}
wait_policy() {
  local end=$((SECONDS+WAIT_SECONDS)) state
  while ((SECONDS<end)); do
    state=$(k -n "$OPERATOR_NAMESPACE" get sriovnetworknodestate "$NODE_NAME" -o json 2>/dev/null || echo '{}')
    if jq -e --arg p "$PF_BDF" --argjson n "$NUM_VFS" '
      (.status.syncStatus=="Succeeded") and
      any(.spec.interfaces[]?; .pciAddress==$p and .numVfs==$n and .eSwitchMode=="switchdev") and
      any(.status.interfaces[]?; .pciAddress==$p and .numVfs==$n and .eSwitchMode=="switchdev")' <<< "$state" >/dev/null; then
      printf '%s\n' "$state" > "$A/node-state.json"
      if k get node "$NODE_NAME" -o json | jq -e --arg r "$RESOURCE_PREFIX/$RESOURCE_NAME" \
          --argjson n "$NUM_VFS" '(.status.allocatable[$r] // "0" | tonumber) >= $n' >/dev/null; then return; fi
    fi
    sleep 5
  done
  die 'Policy/resource reconciliation timed out. Run kube.sh collect and lab.sh collect; do not fake NodeState status.'
}
pod_ip() {
  k -n "$WORKLOAD_NAMESPACE" get pod "$1" -o json | jq -er '
    .metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson|
    .[]|select(.interface=="net1")|.ips[]|select(contains(":")|not)'
}
pod_pci() {
  local key
  key=$(printf '%s' "PCIDEVICE_$RESOURCE_PREFIX/$RESOURCE_NAME" | tr '[:lower:]./-' '[:upper:]___')
  k -n "$WORKLOAD_NAMESPACE" exec "$1" -- python3 -c \
    'import os,sys; print(os.environ.get(sys.argv[1],""))' "$key"
}
case "$ACTION" in
  preflight) preflight ;;
  apply)
    mutation_guard
    [[ ${OPERATOR_REBOOT_ACK:-} == YES ]] || die 'Set OPERATOR_REBOOT_ACK=YES; the operator may reboot this lab worker.'
    [[ $CLUSTER_TYPE == kubernetes ]] || die 'OpenShift: render manifests, then follow the dedicated MCP/KMM runbook; automatic apply is intentionally gated.'
    preflight
    ensure_owned sriovnetworknodepolicy "$POLICY_NAME" "$OPERATOR_NAMESPACE"
    ensure_owned sriovnetworkpoolconfig "$POOL_NAME" "$OPERATOR_NAMESPACE"
    ensure_owned ovsnetwork "$NETWORK_NAME" "$OPERATOR_NAMESPACE"
    if k -n "$OPERATOR_NAMESPACE" get sriovnetworknodepolicy "$POLICY_NAME" -o json > "$A/policy-retry.json" 2>/dev/null; then
      jq -e --arg p "$PF_BDF" --arg r "$RESOURCE_NAME" --argjson n "$NUM_VFS" '
        .spec.nicSelector.rootDevices==[$p] and .spec.numVfs==$n and
        .spec.resourceName==$r and .spec.eSwitchMode=="switchdev" and
        .spec.nodeSelector=={"mock-smartnic.test/target":"dut"}' "$A/policy-retry.json" >/dev/null || die 'Existing owned policy differs from this test; reconcile/clean it up before retrying.'
      remote sudo -n test -f "/var/lib/mock-smartnic-lab/$PF_BDF/persisted"
      remote sudo -n systemctl is-enabled --quiet mock-smartnic-lab.service
      [[ $(remote readlink -f "/sys/bus/pci/devices/$PF_BDF/driver") == /sys/bus/pci/drivers/mock_smartnic_pf ]] || die 'Owned policy retry requires the persistent mock PF binding.'
    else
      "$ROOT/scripts/lab.sh" operator-preflight
    fi
    if k get ns "$WORKLOAD_NAMESPACE" >/dev/null 2>&1; then
      owner=$(k get ns "$WORKLOAD_NAMESPACE" -o json | jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""')
      [[ $owner == "$OWN" ]] || die 'Workload namespace exists and is not owned by this harness.'
    fi
    # Keep the first baseline. Do not overwrite recovery information on retries.
    [[ -f "$A/original-operatorconfig.json" ]] || k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default -o json > "$A/original-operatorconfig.json"
    k label node "$NODE_NAME" mock-smartnic.test/target=dut --overwrite
    python3 "$ROOT/scripts/render.py"
    k apply -f "$ROOT/rendered/00-namespace.yaml"
    k -n "$OPERATOR_NAMESPACE" patch sriovoperatorconfig default --type=merge \
      --patch-file "$ROOT/rendered/05-operatorconfig-patch.json" --dry-run=server >/dev/null
    for f in 10-poolconfig.yaml 20-nodepolicy.yaml 30-ovsnetwork.yaml; do
      k apply --dry-run=server -f "$ROOT/rendered/$f" >/dev/null
    done
    k -n "$OPERATOR_NAMESPACE" patch sriovoperatorconfig default --type=merge --patch-file "$ROOT/rendered/05-operatorconfig-patch.json"
    k apply -f "$ROOT/rendered/10-poolconfig.yaml"
    k apply -f "$ROOT/rendered/20-nodepolicy.yaml"
    wait_policy
    k wait node/"$NODE_NAME" --for=condition=Ready --timeout="${WAIT_SECONDS}s"
    remote sudo -n systemctl is-active --quiet ovs-vswitchd.service || die 'Operator OVS service is not active; collect its drop-in and journal before creating pods.'
    remote sudo -n ovs-vsctl --format=json --columns=other_config list Open_vSwitch > "$A/ovs-config.json"
    jq -e '.data[0][0][1]|map({key:.[0],value:.[1]})|from_entries|.["hw-offload"]=="true" and .["tc-policy"]=="none"' "$A/ovs-config.json" >/dev/null || die 'Operator pool configuration did not reach the actual OVSDB.'
    k apply -f "$ROOT/rendered/30-ovsnetwork.yaml"
    end=$((SECONDS+WAIT_SECONDS))
    until k -n "$WORKLOAD_NAMESPACE" get network-attachment-definition "$NETWORK_NAME" -o json > "$A/nad.json" 2>/dev/null; do
      ((SECONDS<end)) || die 'Generated NetworkAttachmentDefinition did not appear.'
      sleep 3
    done
    actual=$(jq -r '.metadata.annotations["k8s.v1.cni.cncf.io/resourceName"]' "$A/nad.json")
    [[ $actual == "$RESOURCE_PREFIX/$RESOURCE_NAME" ]] || die "NAD resource $actual differs from configured prefix/resource."
    for suffix in a b; do
      ensure_owned pod "mock-ovs-$suffix" "$WORKLOAD_NAMESPACE"
      k apply --dry-run=server -f "$ROOT/rendered/40-pod-$suffix.yaml" >/dev/null
      k apply -f "$ROOT/rendered/40-pod-$suffix.yaml"
    done
    k -n "$WORKLOAD_NAMESPACE" wait pod/mock-ovs-a pod/mock-ovs-b --for=condition=Ready --timeout="${WAIT_SECONDS}s"
    echo 'Pods are ready. Run kube.sh verify to test traffic and offload execution.'
    ;;
  verify)
    preflight
    ia=$(pod_ip mock-ovs-a); ib=$(pod_ip mock-ovs-b)
    [[ -n $ia && -n $ib && $ia != "$ib" ]] || die 'Missing or duplicate net1 addresses.'
    pa=$(pod_pci mock-ovs-a); pb=$(pod_pci mock-ovs-b)
    [[ $pa =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ && $pb =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ && $pa != "$pb" ]] || die 'Resolve distinct allocated PCI BDFs via device-plugin env or pod-resources; do not infer them from pod ordering.'
    "$ROOT/scripts/lab.sh" mapping > "$A/mapping.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- python3 - "$ia" "$ib" < "$ROOT/scripts/ping-probe.py" | tee "$A/ping-a-to-b.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-b -- python3 - "$ib" "$ia" < "$ROOT/scripts/ping-probe.py" | tee "$A/ping-b-to-a.json"
    # Warm up neighbor discovery and OVS megaflow installation; bounded retries.
    for attempt in 1 2 3; do
      if k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- python3 - "$ia" "$ib" --count 30 < "$ROOT/scripts/udp-probe.py"; then break; fi
      [[ $attempt != 3 ]] || die 'Warm-up connectivity failed.'
      sleep 2
    done
    # Keep the tested pair's OVS flows alive during SSH evidence collection;
    # normal OVS idle eviction otherwise removes them between separate reads.
    timeout --foreground 190 "$KUBECTL" --context "$KUBE_CONTEXT" -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- \
      python3 - "$ia" "$ib" --count 15000 --deadline 180 < "$ROOT/scripts/udp-probe.py" > "$A/keepalive.json" &
    keepalive=$!
    trap 'kill "$keepalive" 2>/dev/null || true; wait "$keepalive" 2>/dev/null || true' EXIT
    sleep 3
    "$ROOT/scripts/lab.sh" stats > "$A/stats-before.json"
    "$ROOT/scripts/lab.sh" flows > "$A/flows-before.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- python3 - "$ia" "$ib" < "$ROOT/scripts/udp-probe.py" | tee "$A/a-to-b.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-b -- python3 - "$ib" "$ia" < "$ROOT/scripts/udp-probe.py" | tee "$A/b-to-a.json"
    sleep 2
    "$ROOT/scripts/lab.sh" stats > "$A/stats-after.json"
    "$ROOT/scripts/lab.sh" flows > "$A/flows-after.json"
    "$ROOT/scripts/lab.sh" tc-json > "$A/tc.json"
    "$ROOT/scripts/lab.sh" ovs-evidence > "$A/ovs.txt"
    python3 "$ROOT/scripts/verify-evidence.py" "$A" "$pa" "$pb"
    k -n "$WORKLOAD_NAMESPACE" get pods mock-ovs-a mock-ovs-b -o json > "$A/pods.json"
    wait "$keepalive"
    trap - EXIT
    ;;
  collect)
    k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig,sriovnetworkpoolconfig,sriovnetworknodepolicy,sriovnetworknodestate,ovsnetwork -o yaml > "$A/objects.yaml"
    k -n "$WORKLOAD_NAMESPACE" get pods,network-attachment-definitions -o yaml > "$A/workloads.yaml" || true
    k -n "$WORKLOAD_NAMESPACE" get events --sort-by=.lastTimestamp > "$A/events.txt" || true
    k -n "$OPERATOR_NAMESPACE" get pods -o wide > "$A/operator-pods.txt"
    "$ROOT/scripts/lab.sh" collect > "$A/guest.txt"
    echo "$A"
    ;;
  cleanup)
    mutation_guard
    [[ ${OPERATOR_REBOOT_ACK:-} == YES ]] || die 'Deleting HWOL configuration can also alter/reboot the node.'
    for suffix in a b; do
      ensure_owned pod "mock-ovs-$suffix" "$WORKLOAD_NAMESPACE"
      k -n "$WORKLOAD_NAMESPACE" delete pod "mock-ovs-$suffix" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    done
    ensure_owned ovsnetwork "$NETWORK_NAME" "$OPERATOR_NAMESPACE"
    k -n "$OPERATOR_NAMESPACE" delete ovsnetwork "$NETWORK_NAME" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    ensure_owned sriovnetworknodepolicy "$POLICY_NAME" "$OPERATOR_NAMESPACE"
    k -n "$OPERATOR_NAMESPACE" delete sriovnetworknodepolicy "$POLICY_NAME" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    echo 'Keep the DUT label until NodeState and the managed bridge are cleaned up. Follow the recovery runbook before deleting the pool or restoring the driver.'
    ;;
  *) die 'Usage: kube.sh render|preflight|apply|verify|collect|cleanup' ;;
esac
