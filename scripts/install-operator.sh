#!/usr/bin/env bash
# Optional fresh upstream Kubernetes Helm installation. Not for OLM/OpenShift.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
cluster_guard; mutation_guard
need helm; need git
[[ $CLUSTER_TYPE == kubernetes ]] || die 'Use the documented OpenShift/OLM-compatible deployment path.'
[[ -d ${OPERATOR_SOURCE:-}/.git && -f ${OPERATOR_IMAGE_VALUES:-} ]] || die 'Set OPERATOR_SOURCE and an explicit OPERATOR_IMAGE_VALUES file.'
[[ $(git -C "$OPERATOR_SOURCE" rev-parse HEAD) == "$OPERATOR_REF" ]] || die 'Operator checkout does not match OPERATOR_REF.'
CHART=$OPERATOR_SOURCE/deployment/sriov-network-operator-chart
[[ -f $CHART/Chart.yaml ]] || die 'Pinned chart path missing.'
# No implicit adoption of an existing operator installation.
if k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default >/dev/null 2>&1; then
  die 'An operator configuration already exists. Inspect/upgrade its owner rather than installing another operator.'
fi
if grep -Eq 'REQUIRED_DIGEST|REAL_DIGEST|REGISTRY/' "$OPERATOR_IMAGE_VALUES"; then
  die 'Resolve every placeholder image to an actual compatible pullable image before installation.'
fi
machine=$(k get node "$NODE_NAME" -o json | jq -r '.status.nodeInfo.machineID' | tr -d '-')
vm=$(remote cat /etc/machine-id | tr -d '\r\n-')
[[ -n $vm && $machine == "$vm" ]] || die 'SSH VM and selected Kubernetes node differ.'
other=$(k get nodes -l mock-smartnic.test/target=dut -o json | jq -r --arg n "$NODE_NAME" '.items[]|select(.metadata.name!=$n)|.metadata.name')
[[ -z $other ]] || die 'Another node already has the DUT label; do not broaden operator placement.'
mkdir -p "$ROOT/artifacts/install"
k label node "$NODE_NAME" mock-smartnic.test/target=dut --overwrite
cat > "$ROOT/artifacts/install/lab-values.yaml" <<EOF_VALUES
operator:
  clusterType: kubernetes
  resourcePrefix: "$RESOURCE_PREFIX"
  cniBinPath: /opt/cni/bin
  extraEnv:
    DEV_MODE: "true"
sriovOperatorConfig:
  deploy: true
  configurationMode: daemon
  configDaemonNodeSelector:
    mock-smartnic.test/target: dut
  featureGates:
    manageSoftwareBridges: true
supportedExtraNICs:
  - 'Mock_igb_82576: "8086 10c9 10ca"'
EOF_VALUES
# Default chart admission settings are retained for a new isolated install.
# Existing clusters: preserve existing webhooks; do not disable them as a workaround.
helm template mock-sriov "$CHART" --namespace "$OPERATOR_NAMESPACE" \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  > "$ROOT/artifacts/install/rendered.yaml"
# Review rendered.yaml, including all controller/daemon images and CNI paths.
[[ ${APPROVE_RENDERED_OPERATOR:-} == YES ]] || die 'Rendered manifests saved. Inspect them, then run with APPROVE_RENDERED_OPERATOR=YES.'
helm upgrade --install mock-sriov "$CHART" --kube-context "$KUBE_CONTEXT" \
  --namespace "$OPERATOR_NAMESPACE" --create-namespace \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  --wait --timeout "${WAIT_SECONDS}s"
k -n "$OPERATOR_NAMESPACE" get pods -o wide
