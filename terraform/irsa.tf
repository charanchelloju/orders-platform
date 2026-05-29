# ─── IRSA: IAM Roles for Service Accounts ────────────────────────────────
# Each microservice's pod gets its own IAM role via its K8s ServiceAccount.
# At runtime, AWS SDK in the pod exchanges its mounted JWT for short-lived
# AWS credentials matching this role — no static keys, no manual rotation.

locals {
  # Map service name → schema in Postgres (matches init.sql)
  services_with_db = {
    "order-service"     = "order"
    "payment-service"   = "payment"
    "inventory-service" = "inventory"
  }

  k8s_namespace = "orders-platform"
}

# IAM role per service, trusted by EKS OIDC provider, scoped to one SA.
resource "aws_iam_role" "service" {
  for_each = local.services_with_db

  name = "${var.project}-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${local.k8s_namespace}:${each.key}-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Project = var.project
    Service = each.key
  }
}

# Each service can read ONLY its own DB credential secret.
resource "aws_iam_role_policy" "service_secrets" {
  for_each = local.services_with_db

  name = "secrets-manager-read"
  role = aws_iam_role.service[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = aws_secretsmanager_secret.service_db[each.value].arn
    }]
  })
}

# Output: role ARN per service, fed into Helm values
output "service_role_arns" {
  value = {
    for k, v in aws_iam_role.service : k => v.arn
  }
  description = "Annotate Helm ServiceAccount with these ARNs"
}

# ─── ESO controller's own IRSA role ──────────────────────────────────────
# External Secrets Operator runs as a controller in the cluster and needs
# permission to read all our service secrets from Secrets Manager.
resource "aws_iam_role" "eso" {
  name = "${var.project}-eso"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "eso_read_all" {
  name = "secrets-read-all"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecrets"
      ]
      Resource = [
        for s in aws_secretsmanager_secret.service_db : s.arn
      ]
    }]
  })
}

output "eso_role_arn" {
  value       = aws_iam_role.eso.arn
  description = "Annotate external-secrets-sa with this ARN"
}
