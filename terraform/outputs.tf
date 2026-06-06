# EKS
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
}

# Karpenter
output "karpenter_controller_role_arn" {
  description = "IAM role ARN for Karpenter controller"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Node IAM role name for EC2NodeClass"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS queue name for spot interruption handling"
  value       = module.karpenter.queue_name
}

# IRSA roles — needed in Helmfile values
output "irsa_backup_role_arn" {
  description = "IAM role ARN for the database backup CronJob"
  value       = module.irsa_backup.iam_role_arn
}

output "irsa_external_dns_role_arn" {
  description = "IAM role ARN for ExternalDNS"
  value       = module.irsa_external_dns.iam_role_arn
}

output "irsa_external_secrets_role_arn" {
  description = "IAM role ARN for ExternalSecrets Operator"
  value       = module.irsa_external_secrets.iam_role_arn
}

# S3
output "backup_bucket_name" {
  description = "S3 bucket name for database backups"
  value       = aws_s3_bucket.backups.bucket
}

output "irsa_alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = module.irsa_alb_controller.iam_role_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "region" {
  description = "AWS Region"
  value       = var.region
}
