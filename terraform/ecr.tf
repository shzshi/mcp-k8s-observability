# ECR holds the github-mcp-server image that CI builds and that EKS pulls.
# Kept in Terraform (not created ad-hoc by the workflow) so the registry
# URL is an output the pipeline can consume after apply, and so the node
# IAM role's default ECR pull policy stays aligned with this repo.
resource "aws_ecr_repository" "mcp_server" {
  name                 = "${var.project_name}/github-mcp-server"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # demo project — allows `terraform destroy` without emptying first

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "mcp_server" {
  repository = aws_ecr_repository.mcp_server.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
