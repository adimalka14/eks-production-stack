#!/bin/bash
set -euo pipefail

# DB credentials — override via env vars or edit here
USERNAME="${DB_USERNAME:-appuser}"
PASSWORD="${DB_PASSWORD:?DB_PASSWORD is required}"
HOST="database-postgresql.production.svc.cluster.local"
PORT="5432"
DATABASE="appdb"
REGION="${AWS_REGION:-us-east-1}"
SECRET_NAME="my-app/production/db-credentials"

SECRET_VALUE=$(cat <<EOF
{
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "host": "$HOST",
  "port": "$PORT",
  "database": "$DATABASE"
}
EOF
)

# Create or update the secret
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
  echo "Secret exists — updating..."
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --region "$REGION"
else
  echo "Creating secret..."
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --region "$REGION"
fi

echo "Done: $SECRET_NAME"
