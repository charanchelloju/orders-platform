output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_registry" {
  value       = trimsuffix(replace(values(aws_ecr_repository.service)[0].repository_url, "/${values(aws_ecr_repository.service)[0].name}", ""), "/")
  description = "Set this as GitHub Actions variable ECR_REGISTRY"
}

output "github_oidc_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Set this as GitHub Actions variable AWS_OIDC_ROLE_ARN"
}

output "rds_endpoint" {
  value       = aws_db_instance.postgres.endpoint
  description = "Postgres host for JDBC URL"
  sensitive   = true
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# ─── Secret ARNs (referenced by Helm values to grant pod access) ───────
output "db_master_secret_arn" {
  value       = aws_secretsmanager_secret.db_master.arn
  description = "ARN of the RDS master password secret"
}

output "service_db_secret_arns" {
  value = {
    for k, v in aws_secretsmanager_secret.service_db : k => v.arn
  }
  description = "Per-service DB credential secret ARNs"
}
