module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.15"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  # Stream control plane logs to CloudWatch
  # Log group: /aws/eks/${cluster_name}/cluster
  cluster_enabled_log_types = [
    "api",                # Kubernetes API server requests
    "audit",              # Who did what (compliance + debugging)
    "authenticator",      # IAM-based auth events
    "controllerManager",  # Built-in controllers
    "scheduler",          # Pod scheduling decisions
  ]
  cloudwatch_log_group_retention_in_days = 14

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      # CSI driver needs IAM permissions to attach/detach EBS volumes.
      # Without this it hangs in CREATING forever.
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
  }

  eks_managed_node_groups = {
    workers = {
      ami_type       = "AL2_x86_64"
      instance_types = ["t3.small"]               # ~$0.021/hour each — fits credits plan
      min_size       = 2
      max_size       = 4
      desired_size   = 3
      disk_size      = 30
    }
  }

  tags = {
    Project = var.project
  }
}

# ─── IRSA role for the EBS CSI driver ──────────────────────────────────────
# The CSI driver pods run with the "ebs-csi-controller-sa" service account in
# kube-system. We trust that SA via OIDC and attach AWS's managed policy.
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.project}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Project = var.project }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
