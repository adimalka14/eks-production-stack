#!/bin/bash
set -euo pipefail

TERRAFORM_DIR="$(dirname "$0")/../terraform"
OUTPUT_FILE="$(dirname "$0")/../helm/values/generated.yaml"
EC2NODECLASS_FILE="$(dirname "$0")/../helm/manifests/ec2nodeclass.yaml"
EXT_SECRETS_FILE="$(dirname "$0")/../helm/values/external-secrets.yaml"

echo "Reading Terraform outputs..."
cd "$TERRAFORM_DIR"

KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
KARPENTER_NODE_ROLE=$(terraform output -raw karpenter_node_role_name)
KARPENTER_QUEUE=$(terraform output -raw karpenter_queue_name)
EXTERNAL_DNS_ROLE_ARN=$(terraform output -raw irsa_external_dns_role_arn)
EXTERNAL_SECRETS_ROLE_ARN=$(terraform output -raw irsa_external_secrets_role_arn)
BACKUP_ROLE_ARN=$(terraform output -raw irsa_backup_role_arn)
CLUSTER_NAME=$(terraform output -raw cluster_name)

cat > "$OUTPUT_FILE" <<EOF
# Auto-generated from terraform output — do not edit manually
# Run scripts/generate-values.sh to regenerate

clusterName: "${CLUSTER_NAME}"

karpenter:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${KARPENTER_ROLE_ARN}"
  settings:
    clusterName: "${CLUSTER_NAME}"
    interruptionQueue: "${KARPENTER_QUEUE}"

externalDns:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${EXTERNAL_DNS_ROLE_ARN}"

backup:
  irsaRoleArn: "${BACKUP_ROLE_ARN}"
  instanceProfile: "${KARPENTER_NODE_ROLE}"
EOF

# Update IAM role in ec2nodeclass.yaml
sed -i "s/role: Karpenter-.*/role: ${KARPENTER_NODE_ROLE}/" "$EC2NODECLASS_FILE"

# Update IAM role in external-secrets.yaml
sed -i "s|eks.amazonaws.com/role-arn: .*|eks.amazonaws.com/role-arn: \"${EXTERNAL_SECRETS_ROLE_ARN}\"|" "$EXT_SECRETS_FILE"

echo "Generated: $OUTPUT_FILE and updated manifests"
