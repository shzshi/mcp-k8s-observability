terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }

  # Remote state is required here (not optional) because Terraform runs
  # from ephemeral GitHub Actions runners — local state would vanish
  # after every CI run, and the next apply would try to recreate
  # everything from scratch. Values are passed via `terraform init
  # -backend-config=...` in the CI workflow rather than hardcoded here,
  # so the same config works whether you're running locally against a
  # personal bucket or in CI against a project one.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

# The helm/kubernetes providers authenticate against the EKS cluster this
# same `terraform apply` just created — using an exec-based auth plugin
# means no static kubeconfig file needs to exist beforehand.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true # cost optimisation for a personal project — one NAT, not one per AZ
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.project_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 3
      desired_size   = 1 # small + cheap for a personal proof project; bump for real load testing
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND" # meaningful cost saving for non-production workloads
    }
  }

  # Explicit access entries instead of relying on "whoever ran apply" —
  # since this cluster gets destroyed/recreated regularly and apply
  # sometimes runs locally, sometimes via the CI pipeline's OIDC role,
  # an implicit creator-only grant would silently lock out whichever
  # identity DIDN'T run that particular apply.
  enable_cluster_creator_admin_permissions = false

  access_entries = {
     local_admin = {
       principal_arn = var.local_admin_iam_arn
       policy_associations = {
         admin = {
           policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
           access_scope = { type = "cluster" }
         }
       }
     }
     ci_deploy_role = {
       principal_arn = aws_iam_role.github_actions_deploy_lookup.arn
       policy_associations = {
         admin = {
           policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
           access_scope = { type = "cluster" }
         }
       }
     }
   }

  tags = local.tags
}

locals {
  tags = {
    Project     = var.project_name
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}
