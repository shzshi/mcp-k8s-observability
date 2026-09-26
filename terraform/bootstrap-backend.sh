#!/usr/bin/env bash
# One-time setup: creates the S3 bucket that Terraform's remote backend
# needs. Run this ONCE, manually, before the first `terraform init` —
# Terraform can't create the backend it's about to store its own state
# in (chicken-and-egg problem), so this step lives outside Terraform
# entirely, using the AWS CLI directly.
#
# No DynamoDB table needed: Terraform 1.10+ supports native S3 state
# locking (`use_lockfile = true`) using S3 conditional writes, which
# replaces the old DynamoDB-table-based locking approach entirely.
#
# Usage: ./bootstrap-backend.sh <bucket-name> [region]

set -euo pipefail

BUCKET="${1:?Usage: $0 <bucket-name> [region]}"
REGION="${2:-eu-west-2}"

echo "Creating S3 bucket: $BUCKET in $REGION"
aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Done. Now fill this into terraform/backend.hcl (local) and the"
echo "TF_STATE_BUCKET repo variable (CI):"
echo "  bucket: $BUCKET"
echo "  region: $REGION"
