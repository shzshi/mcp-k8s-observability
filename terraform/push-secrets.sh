#!/usr/bin/env bash
# Pushes real secret values into the Secrets Manager secret Terraform
# created (empty, deliberately — see terraform/secrets.tf for why).
# Run this once after `terraform apply`, and again any time a key
# rotates — ESO picks up the change automatically within its
# refreshInterval (5m by default), no pod restart or redeploy needed.
#
# Usage: ./push-secrets.sh <secret-arn-or-name>

set -euo pipefail

SECRET_ID="${1:?Usage: $0 <secret-arn-or-name>}"

read -rp "GitHub token (ghp_...): " GITHUB_TOKEN
read -rp "Langfuse public key (pk-lf-...): " LANGFUSE_PUBLIC_KEY
read -rsp "Langfuse secret key (sk-lf-...): " LANGFUSE_SECRET_KEY
echo

PAYLOAD=$(cat <<JSON
{
  "github-token": "${GITHUB_TOKEN}",
  "langfuse-public-key": "${LANGFUSE_PUBLIC_KEY}",
  "langfuse-secret-key": "${LANGFUSE_SECRET_KEY}"
}
JSON
)

aws secretsmanager put-secret-value \
    --secret-id "$SECRET_ID" \
    --secret-string "$PAYLOAD"

echo "Pushed. ESO will sync this into the github-mcp-secrets K8s Secret"
echo "within its refresh interval (default 5m) — check with:"
echo "  kubectl get externalsecret github-mcp-secrets -o wide"
echo "  kubectl get secret github-mcp-secrets -o jsonpath='{.data}' | jq"
