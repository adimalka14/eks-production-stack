#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/terraform"
HELM_DIR="$REPO_ROOT/helm"

echo "━━━ WARNING: This will destroy everything ━━━"
read -p "Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

echo "━━━ [1/3] Remove Karpenter manifests ━━━"
# IMPORTANT: Delete External Secrets first! 
# If Karpenter nodes are deleted first, the webhook dies and prevents SecretStore deletion.
kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml" --ignore-not-found
kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml" --ignore-not-found

# Delete Karpenter manifests
kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml" --ignore-not-found
kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml" --ignore-not-found
kubectl delete -f "$HELM_DIR/manifests/gp3-storageclass.yaml" --ignore-not-found

echo "━━━ [2/3] Helmfile destroy ━━━"
cd "$HELM_DIR"
helmfile destroy

echo "━━━ [3/3] Terraform destroy ━━━"
cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

echo ""
echo "━━━ Destroy complete ━━━"
