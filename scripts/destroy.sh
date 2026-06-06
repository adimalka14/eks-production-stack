#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/terraform"
HELM_DIR="$REPO_ROOT/helm"

echo "━━━ WARNING: This will destroy everything ━━━"
read -p "Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

echo "━━━ [1/5] Delete External Secrets (To prevent finalizer deadlocks) ━━━"
# We must delete the secrets BEFORE helmfile destroys the ExternalSecrets controller
kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml" --ignore-not-found
kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml" --ignore-not-found

echo "━━━ [2/5] Remove Karpenter NodePools and EC2NodeClasses ━━━"
# We delete Karpenter custom resources while the Karpenter controller is still running,
# allowing it to drain nodes and terminate EC2 instances gracefully.
kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml" --ignore-not-found
kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml" --ignore-not-found

echo "━━━ [3/5] Destroy Applications (production namespace) ━━━"
# We destroy the apps first so the ALB Controller and VPC CNI have time to clean up 
# AWS Load Balancers, Security Groups, and Elastic Network Interfaces (ENIs).
cd "$HELM_DIR"
helmfile -n production destroy || true

echo "Waiting 45 seconds for Karpenter nodes to terminate and ALBs to be deleted..."
sleep 45

echo "━━━ [4/5] Destroy Infrastructure Controllers via Helmfile ━━━"
# Destroy remaining controllers (ALB controller, Karpenter operator, prometheus, external secrets, etc.)
cd "$HELM_DIR"
helmfile destroy || true
kubectl delete -f "$HELM_DIR/manifests/gp3-storageclass.yaml" --ignore-not-found

# Safety Net: Clean up any orphan Security Groups created dynamically by the AWS Load Balancer Controller
echo "Checking for orphan AWS Load Balancer security groups..."
CLUSTER_NAME="eks-production-cluster"
ORPHAN_SGS=$(aws ec2 describe-security-groups \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
    --query "SecurityGroups[*].GroupId" --output text 2>/dev/null || echo "")

for sg in $ORPHAN_SGS; do
    if [ -n "$sg" ]; then
        echo "Deleting orphan security group: $sg"
        aws ec2 delete-security-group --group-id "$sg" || true
    fi
done

echo "━━━ [5/5] Emptying S3 Backup Bucket and Terraform Destroy ━━━"
python3 "$REPO_ROOT/scripts/empty_bucket.py" || true

cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

echo ""
echo "━━━ Destroy complete ━━━"
