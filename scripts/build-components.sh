#!/usr/bin/env bash
# Rebuild source-pinned userspace images. Registry delivery remains explicit.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need go; need git; need podman
[[ -d ${OPERATOR_SOURCE:-}/.git && -d ${OVS_CNI_SOURCE:-}/.git ]] || die 'Set OPERATOR_SOURCE and OVS_CNI_SOURCE to dedicated pinned checkouts.'
[[ $(git -C "$OPERATOR_SOURCE" rev-parse HEAD) == "$OPERATOR_REF" ]] || die 'Wrong operator source.'
[[ $(git -C "$OVS_CNI_SOURCE" rev-parse HEAD) == 19262a0c9f304dc9cb04454afeed77e6ca77950b ]] || die 'Wrong ovs-cni source.'
for role in operator daemon webhook; do
 var=RUNTIME_IMAGE_${role^^}
 [[ ${!var:-} =~ ^(.+@)?sha256:[0-9a-f]{64}$ ]] || die "Set $var to an inspected immutable runtime parent."
done
patch_source() {
 local tree=$1 patch=$2
 if git -C "$tree" apply --reverse --check "$patch" >/dev/null 2>&1; then return; fi
 git -C "$tree" apply --check "$patch"
 git -C "$tree" apply "$patch"
}
patch_source "$OPERATOR_SOURCE" "$ROOT/patches/operator-systemd-ovs.patch"
patch_source "$OVS_CNI_SOURCE" "$ROOT/patches/ovs-cni-vf-info.patch"
(cd "$OPERATOR_SOURCE"; go test ./pkg/utils -run '^TestRenderOtherOvsConfigOption$' -count=1;
 go test ./pkg/host/internal/service -run '^TestOVSUnitArguments$' -count=1)
export GOOS=linux GOARCH=amd64 CGO_ENABLED=0
(cd "$OPERATOR_SOURCE"; BIN_PATH=build/_output/cmd make _build-manager _build-sriov-network-config-daemon _build-webhook _build-sriov-network-operator-config-cleanup)
mkdir -p "$OVS_CNI_SOURCE/build/mock-smartnic-bin"
(cd "$OVS_CNI_SOURCE"; for pair in ovs:plugin ovs-mirror-producer:mirror-producer ovs-mirror-consumer:mirror-consumer marker:marker; do
 go build -mod=vendor -tags no_openssl -o "build/mock-smartnic-bin/${pair%%:*}" "./cmd/${pair#*:}"; done)
for role in operator daemon webhook ovs-cni; do
 context="$ROOT/artifacts/images/$role"
 mkdir -p "$context"
 case $role in
 operator)
  cp "$OPERATOR_SOURCE/build/_output/cmd/manager" "$context/manager"
  cp "$OPERATOR_SOURCE/build/_output/cmd/sriov-network-operator-config-cleanup" "$context/"
  cp -a "$OPERATOR_SOURCE/bindata" "$context/"
  runtime=$RUNTIME_IMAGE_OPERATOR ;;
 daemon)
  cp "$OPERATOR_SOURCE/build/_output/cmd/sriov-network-config-daemon" "$context/"
  cp -a "$OPERATOR_SOURCE/bindata" "$context/"
  runtime=$RUNTIME_IMAGE_DAEMON ;;
 webhook) cp "$OPERATOR_SOURCE/build/_output/cmd/webhook" "$context/"; runtime=$RUNTIME_IMAGE_WEBHOOK ;;
 ovs-cni)
  cp "$OVS_CNI_SOURCE/build/mock-smartnic-bin/"{ovs,ovs-mirror-producer,ovs-mirror-consumer,marker} "$context/"
  printf '%s\n' 19262a0c9f304dc9cb04454afeed77e6ca77950b > "$context/.version"
  runtime=$RUNTIME_IMAGE_WEBHOOK ;;
 esac
 patch=operator-systemd-ovs.patch; revision=a5588da2-fix1
 if [[ $role == ovs-cni ]]; then patch=ovs-cni-vf-info.patch; revision=19262a0c-fix1; fi
 patch_sha=$(sha256sum "$ROOT/patches/$patch" | cut -d' ' -f1)
 podman build --platform linux/amd64 --pull=never --network=none \
  --build-arg "RUNTIME_IMAGE=$runtime" --build-arg "PATCH_SHA256=$patch_sha" \
  -f "$ROOT/containers/Containerfile.$role" -t "localhost/mock-smartnic-$role:$revision" "$context"
done
