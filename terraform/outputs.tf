output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret — use this with `aws secretsmanager put-secret-value`"
  value       = aws_secretsmanager_secret.mcp_server.arn
}
