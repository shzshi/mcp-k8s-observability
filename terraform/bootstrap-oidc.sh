#!/usr/bin/env bash
# One-time setup: creates the GitHub Actions OIDC provider + IAM role
# that the CI pipeline authenticates as. Run this ONCE, manually, from
# your local machine — deliberately kept OUTSIDE Terraform's main state
# because that state gets `terraform destroy`'d between sessions to save
# cost, and destroying this role would break the very pipeline that
# needs it to run the next `apply`.
#
# Usage: ./bootstrap-oidc.sh <github-owner> <github-repo> [project-name]

set -euo pipefail

GITHUB_OWNER="${1:?Usage: $0 <github-owner> <github-repo> [project-name]}"
GITHUB_REPO="${2:?Usage: $0 <github-owner> <github-repo> [project-name]}"
PROJECT_NAME="${3:-mcp-obs-demo}"
ROLE_NAME="${PROJECT_NAME}-github-actions-deploy"

 # GitHub changed the default OIDC `sub` claim format on 2026-07-15: new
# repos now embed immutable numeric owner/repo IDs instead of names
# (e.g. repo:owner@123/repo@456:... instead of repo:owner/repo:...),
# to stop attacks that recycle a deleted org/repo name. Rather than
# hardcode that cutoff date here, we ask GitHub directly what format
# THIS repo actually uses — this stays correct even if GitHub's rules
# change again later.
echo "Looking up this repo's actual OIDC subject claim format..."
SUB_PREFIX=$(gh api "repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/oidc/customization/sub" \
     --jq '.sub_claim_prefix' 2>/dev/null || echo "")

 if [ -z "$SUB_PREFIX" ] || [ "$SUB_PREFIX" = "null" ]; then
     echo "Could not fetch sub_claim_prefix via API — falling back to classic name-based format."
     echo "(Needs 'gh auth login' with repo access, or GitHub Enterprise Server, which doesn't have this endpoint.)"
     SUB_PREFIX="repo:${GITHUB_OWNER}/${GITHUB_REPO}"
 else
     echo "Using subject prefix: ${SUB_PREFIX}"
 fi

# GitHub's OIDC thumbprint — stable, documented value; skip creation if
# a provider for this URL already exists (re-running this script should
# be safe/idempotent).
EXISTING_PROVIDER=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
    --output text)

if [ -z "$EXISTING_PROVIDER" ]; then
    echo "Creating GitHub OIDC provider..."
    PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
        --url "https://token.actions.githubusercontent.com" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
        --query "OpenIDConnectProviderArn" --output text)
else
    echo "OIDC provider already exists, reusing it."
    PROVIDER_ARN="$EXISTING_PROVIDER"
fi

TRUST_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${PROVIDER_ARN}"},
    "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
            "${SUB_PREFIX}:ref:refs/heads/main",
            "${SUB_PREFIX}:pull_request",
            "${SUB_PREFIX}:environment:production",
            "${SUB_PREFIX}:environment:development"
        ]
      }
    }
  }]
}
JSON
)

echo "Creating/updating IAM role: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
fi

# Personal sandbox account, short-lived project: broad access traded for
# setup speed. Do NOT do this for a client's AWS account — scope this to
# exactly the EKS/EC2/IAM/S3/ECR/Secrets Manager actions the pipeline calls.
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)

echo ""
echo "Done. Set this as a GitHub repo secret:"
echo "  gh secret set AWS_DEPLOY_ROLE_ARN --repo ${GITHUB_OWNER}/${GITHUB_REPO} --body \"${ROLE_ARN}\""