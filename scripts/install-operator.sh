#!/usr/bin/env bash
# Fresh installation or explicit upgrade of the existing Helm owner. Not OLM.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
cluster_guard; mutation_guard
need helm; need git
[[ $CLUSTER_TYPE == kubernetes ]] || die 'Use the documented OpenShift/OLM-compatible deployment path.'
[[ -d ${OPERATOR_SOURCE:-}/.git && -f ${OPERATOR_IMAGE_VALUES:-} ]] || die 'Set OPERATOR_SOURCE and an explicit OPERATOR_IMAGE_VALUES file.'
[[ $(git -C "$OPERATOR_SOURCE" rev-parse HEAD) == "$OPERATOR_REF" ]] || die 'Operator checkout does not match OPERATOR_REF.'
CHART=$OPERATOR_SOURCE/deployment/sriov-network-operator-chart
[[ -f $CHART/Chart.yaml ]] || die 'Pinned chart path missing.'
MODE=${1:-install}
RELEASE=${2:-mock-sriov}
[[ $MODE == install || $MODE == upgrade ]] || die 'Usage: install-operator.sh [install|upgrade] [release]'
[[ $RELEASE =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 'Invalid Helm release name.'
if [[ $MODE == upgrade ]]; then
  owner=$(k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default -o json | jq -r '.metadata.annotations["meta.helm.sh/release-name"] // ""')
  [[ $owner == "$RELEASE" ]] || die 'Upgrade release must match the existing operator configuration owner.'
  helm status "$RELEASE" --namespace "$OPERATOR_NAMESPACE" --kube-context "$KUBE_CONTEXT" >/dev/null
elif k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default >/dev/null 2>&1; then
  die 'An operator configuration already exists. Use upgrade with its explicit Helm release owner.'
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
if [[ $MODE == upgrade ]]; then
  # Preserve gates and show existing admission settings in the review render.
  k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default -o json > "$ROOT/artifacts/install/operatorconfig-before.json"
  RELEASE_FOR_RENDER="$RELEASE" python3 - "$ROOT/artifacts/install/operatorconfig-before.json" "$ROOT/artifacts/install/lab-values.yaml" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
values=json.loads(subprocess.check_output([
    'helm','get','values',os.environ.get('RELEASE_FOR_RENDER', 'sriov-network-operator'),
    '--namespace',os.environ['OPERATOR_NAMESPACE'],'--kube-context',os.environ['KUBE_CONTEXT'],'-o','json']))
admission=values.get('operator',{}).get('admissionControllers',{})
if admission.get('certificates',{}).get('custom',{}).get('enabled'):
    raise SystemExit('Custom certificate values require a separate owner-reviewed upgrade; do not export them.')
admission={k:v for k,v in admission.items() if k in ('enabled','networkPolicy','certificates')}
admission['certificates']={k:v for k,v in admission.get('certificates',{}).items()
                         if k in ('secretNames','certManager')}
spec=json.loads(Path(sys.argv[1]).read_text())['spec']
lab={'operator':{'clusterType':'kubernetes','resourcePrefix':os.environ['RESOURCE_PREFIX'],
      'cniBinPath':'/opt/cni/bin','extraEnv':{'DEV_MODE':'true'},'admissionControllers':admission},
     'sriovOperatorConfig':{'deploy':True,'configurationMode':'daemon',
      'configDaemonNodeSelector':{'mock-smartnic.test/target':'dut'},
      'featureGates':{**spec.get('featureGates',{}),'manageSoftwareBridges':True}},
     'supportedExtraNICs':['Mock_igb_82576: "8086 10c9 10ca"']}
Path(sys.argv[2]).write_text(json.dumps(lab,indent=2)+'\n')
PY
fi
# Default chart admission settings are retained for a new isolated install.
# Existing clusters: preserve existing webhooks; do not disable them as a workaround.
helm template "$RELEASE" "$CHART" --namespace "$OPERATOR_NAMESPACE" \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  > "$ROOT/artifacts/install/rendered.yaml"
# Review rendered.yaml, including all controller/daemon images and CNI paths.
[[ ${APPROVE_RENDERED_OPERATOR:-} == YES ]] || die 'Rendered manifests saved. Inspect them, then run with APPROVE_RENDERED_OPERATOR=YES.'
if [[ $MODE == upgrade ]]; then
  # Keep existing admission, certificates, and release settings. Never export secrets.
  helm upgrade "$RELEASE" "$CHART" --kube-context "$KUBE_CONTEXT" \
    --namespace "$OPERATOR_NAMESPACE" --reuse-values --dry-run --hide-secret \
    -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" >/dev/null
  # Helm upgrades do not update crds/. Keep the source-pinned operator API aligned;
  # the shared Multus NAD CRD belongs to the existing installation.
  for crd in "$CHART"/crds/sriovnetwork.openshift.io_*.yaml; do
    k apply -f "$crd"
  done
  helm upgrade "$RELEASE" "$CHART" --kube-context "$KUBE_CONTEXT" \
    --namespace "$OPERATOR_NAMESPACE" --reuse-values \
    -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
    --wait --timeout "${WAIT_SECONDS}s"
else
helm upgrade --install "$RELEASE" "$CHART" --kube-context "$KUBE_CONTEXT" \
  --namespace "$OPERATOR_NAMESPACE" --create-namespace \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  --wait --timeout "${WAIT_SECONDS}s"
fi
k -n "$OPERATOR_NAMESPACE" get pods -o wide
