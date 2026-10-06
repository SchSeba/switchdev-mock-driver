# Example manifests

These are reviewable examples with a sample PF BDF, namespace and workload image.
Use `scripts/kube.sh render` to generate your real lab inputs. Do not apply these
examples blindly. Both lanes include operator bridge-management patch, a hardware-
offload pool, switchdev node policy, OVSNetwork and two resource-requesting pods.

Kubernetes uses a node-selected pool with no nonempty HWOL name. OpenShift uses an
existing dedicated MCP name and omits nodeSelector/maxUnavailable in that object.
Read docs/04-kubernetes-flow.md before applying. These schemas were rendered and
parsed locally, but no live Kubernetes admission or reconciliation was exercised.
