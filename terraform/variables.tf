variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "orders-platform"
}

variable "github_org" {
  description = "Your GitHub org/username for OIDC trust"
  type        = string
}

variable "github_repo" {
  description = "Repo name for OIDC trust"
  type        = string
  default     = "orders-platform"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "alert_email" {
  description = "Email to receive CloudWatch alarm notifications (you'll confirm via inbox)"
  type        = string
}
