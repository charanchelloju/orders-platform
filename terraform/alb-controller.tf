# ─── AWS Load Balancer Controller ────────────────────────────────────────
# Watches Ingress + Service objects in the cluster and provisions real AWS
# ALBs (and NLBs) to match. Without this, an Ingress resource in K8s does
# nothing on EKS — there's no built-in cloud controller for ALB.
#
# Flow:
#   1. We apply Ingress YAML to K8s
#   2. This controller (a pod in kube-system) sees the Ingress
#   3. Calls AWS APIs to create:
#        - ALB
#        - Target Group(s)
#        - Listener rules
#   4. Writes the ALB's DNS name back into the Ingress status field
#
# IRSA: the controller's K8s ServiceAccount (kube-system/aws-load-balancer-
# controller) is mapped to an AWS IAM role with permissions to manage ELBs.

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project}-alb-controller"
  description = "Permissions for the AWS Load Balancer Controller to manage ALBs"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.project}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Project = var.project }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ─── Install the controller via Helm ─────────────────────────────────────
# Chart provisioned by AWS, maintained by the K8s SIG-Network team.
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = module.vpc.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
        }
      }

      # Run 2 replicas for HA (controller leader-elects)
      replicaCount = 2

      resources = {
        requests = { cpu = "100m", memory = "200Mi" }
        limits   = { cpu = "200m", memory = "500Mi" }
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller,
  ]
}

output "alb_controller_role_arn" {
  value       = aws_iam_role.alb_controller.arn
  description = "IRSA role for the AWS Load Balancer Controller"
}
