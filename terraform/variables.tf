variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2" # London — closest region if you're UK-based, lower latency for testing
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "mcp-obs-demo"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "demo"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "EC2 instance type for the EKS managed node group"
  type        = string
  default     = "t3.small" # cheapest reasonable size for running a couple of small pods
}

variable "eso_namespace" {
  description = "Namespace to install External Secrets Operator into"
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account_name" {
  description = "Kubernetes ServiceAccount name used by ESO, bound to the IRSA role"
  type        = string
  default     = "external-secrets-sa"
}
