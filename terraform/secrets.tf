# ---------------------------------------------------------------------------
# AWS Secrets Manager: holds the real Langfuse + GitHub credentials.
#
# The secret is created empty here (Terraform shouldn't own real secret
# values in state — that's a well-known anti-pattern, since state files
# are often less protected than the secrets store itself). You push the
# actual values out-of-band via the AWS CLI after `terraform apply`
# (see README "Pushing secret values").
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "mcp_server" {
  name        = "${var.project_name}/mcp-server-secrets"
  description = "Langfuse + GitHub credentials for the github-mcp-server pod"

  # This project gets destroyed and recreated every session to save
  # cost (see README teardown instructions) — the default 30-day
  # recovery window would otherwise block recreating a secret with
  # the same name on every subsequent `terraform apply`. Force
  # immediate deletion instead of the soft-delete/recovery window.
  recovery_window_in_days = 0

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IRSA: lets the External Secrets Operator pod assume an IAM role scoped
# to read ONLY this one secret — not blanket Secrets Manager access. This
# least-privilege scoping is the detail that separates "I wired up IRSA"
# from "I wired up IRSA properly."
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eso_secrets_read" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.mcp_server.arn]
  }
}

resource "aws_iam_policy" "eso_secrets_read" {
  name   = "${var.project_name}-eso-secrets-read"
  policy = data.aws_iam_policy_document.eso_secrets_read.json
}

data "aws_iam_policy_document" "eso_irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.eso_namespace}:${var.eso_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso_irsa" {
  name               = "${var.project_name}-eso-irsa"
  assume_role_policy = data.aws_iam_policy_document.eso_irsa_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "eso_irsa" {
  role       = aws_iam_role.eso_irsa.name
  policy_arn = aws_iam_policy.eso_secrets_read.arn
}

# ---------------------------------------------------------------------------
# Install External Secrets Operator itself via the Helm provider — keeps
# the whole chain (cluster -> operator -> secret sync) as one `terraform
# apply`, rather than a manual `helm install` step a README could get out
# of sync with.
# ---------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = var.eso_namespace
  create_namespace = true
  version          = "0.10.4"

  set {
    name  = "serviceAccount.name"
    value = var.eso_service_account_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso_irsa.arn
  }

  depends_on = [module.eks]
}
