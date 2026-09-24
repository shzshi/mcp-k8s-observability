#!/usr/bin/env bash
# One-time setup: creates the S3 bucket + DynamoDB table that Terraform's
# remote backend needs. Run this ONCE, manually, before the first
# `terraform init` — Terraform can't create the backend it's about to
# store its own state in (chicken-and-egg problem), so this step lives
# outside Terraform entirely, using the AWS CLI directly.
#
# Usage: ./bootstrap-backend.sh <bucket-name> <dynamodb-table-name> [region]

set -euo pipefail

BUCKET="${1:?Usage: $0 <bucket-name> <dynamodb-table-name> [region]}"
TABLE="${2:?Usage: $0 <bucket-name> <dynamodb-table-name> [region]}"
REGION="${3:-eu-west-2}"

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

echo "Creating DynamoDB lock table: $TABLE"
aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"

echo "Done. Now fill these into terraform/backend.hcl (local) and the"
echo "TF_STATE_BUCKET / TF_LOCK_TABLE repo variables (CI):"
echo "  bucket:         $BUCKET"
echo "  dynamodb_table: $TABLE"
echo "  region:         $REGION"
