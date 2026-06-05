#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/terraform"
HELM_DIR="$REPO_ROOT/helm"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# ── Required env vars ────────────────────────────────────────────────────────
: "${DB_PASSWORD:?DB_PASSWORD is required}"

echo "━━━ [1/6] Terraform init + apply ━━━"
cd "$TERRAFORM_DIR"
terraform init -upgrade
terraform apply -auto-approve

echo "━━━ [2/6] Configure kubectl ━━━"
CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw cluster_endpoint | grep -oP '(?<=eks\.).*(?=\.amazonaws)' || echo "us-east-1")
aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER_NAME"

echo "━━━ [3/6] Generate Helm values from Terraform outputs ━━━"
bash "$SCRIPTS_DIR/generate-values.sh"

echo "━━━ [4/6] Create secrets in AWS Secrets Manager ━━━"
bash "$SCRIPTS_DIR/create-secrets.sh"

echo "━━━ [5/6] Helmfile sync ━━━"
cd "$HELM_DIR"
helm dependency build charts/database
helmfile sync

echo "━━━ [6/6] Apply Karpenter + ExternalSecrets manifests ━━━"
echo "Waiting for Karpenter to be ready..."
kubectl rollout status deployment/karpenter -n karpenter --timeout=180s

kubectl apply -f "$HELM_DIR/manifests/gp3-storageclass.yaml"
kubectl apply -f "$HELM_DIR/manifests/ec2nodeclass.yaml"
kubectl apply -f "$HELM_DIR/manifests/nodepool.yaml"

echo "Waiting for ExternalSecrets webhook to be ready..."
kubectl rollout status deployment/external-secrets-webhook -n external-secrets --timeout=300s

kubectl apply -f "$HELM_DIR/manifests/cluster-secret-store.yaml"
kubectl apply -f "$HELM_DIR/manifests/external-secret.yaml"

echo ""
echo "━━━ Deploy complete ━━━"
echo "Run: kubectl get pods -A"
