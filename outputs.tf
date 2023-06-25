# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

# output "eks" {
#   description = "EKS"
#   value       = module.eks
# }

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

# output "ingress" {
#   description = "Ingress Nginx"
#   value       = helm_release.ingress-nginx
# }

output "aws_root_account_id" {
  value = local.aws_root_account_id
}

# output "load-balancer-role-trust-policy" {
#   value = local.load-balancer-role-trust-policy
# }

# output "load-balancer-role-trust-policy" {
#   value = aws_iam_role.aws_eks_load_balancer_controller
# }