# ─── CloudWatch alarms + SNS notification topic ───────────────────────────
# Watches AWS-managed resources (RDS, NAT) since those metrics live in
# CloudWatch by default. Application metrics are still in Prometheus.
# Alarms fan out to one SNS topic; one email subscription confirms via inbox.

# ─── SNS topic — single fan-out point for alerts ──────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"

  tags = {
    Project = var.project
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email

  # Note: AWS sends a confirmation email — you must click the link
  # before alerts will be delivered.
}

# ─── RDS alarms ───────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project}-rds-cpu-high"
  alarm_description   = "RDS CPU > 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.project}-rds-storage-low"
  alarm_description   = "RDS free storage < 5 GB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = 5000000000   # 5 GB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${var.project}-rds-connections-high"
  alarm_description   = "RDS DB connections > 80 (db.t3.micro limit is ~100)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project }
}

# ─── NAT Gateway alarm ────────────────────────────────────────────────────
# NAT errors usually mean port exhaustion or outbound network issues —
# can break image pulls, AWS SDK calls, Kafka cross-AZ traffic.
resource "aws_cloudwatch_metric_alarm" "nat_errors" {
  alarm_name          = "${var.project}-nat-errors"
  alarm_description   = "NAT Gateway port allocation errors > 10 in 1 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ErrorPortAllocation"
  namespace           = "AWS/NATGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  # NAT Gateway ID isn't directly exposed; this alarm watches all NAT gateways
  # in the account / region (fine for a demo with one VPC)

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project }
}

# ─── EKS node alarm (worker pressure) ─────────────────────────────────────
# Uses Container Insights metrics if you opt in; falls back to EC2 metrics.
# For simplicity we watch the EKS managed node group's EC2 instances at the
# group level via the AWS/EC2 namespace.
resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  alarm_name          = "${var.project}-eks-node-cpu-high"
  alarm_description   = "Any EKS worker node CPU > 85% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 10
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = "eks-${var.project}-eks"   # AWS prepends this
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project }
}

output "sns_alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "Subscribe additional endpoints (Slack webhook, PagerDuty) to this"
}

output "cloudwatch_logs_groups" {
  value = {
    eks_control_plane = "/aws/eks/${module.eks.cluster_name}/cluster"
    rds_postgresql    = "/aws/rds/instance/${aws_db_instance.postgres.id}/postgresql"
    rds_upgrade       = "/aws/rds/instance/${aws_db_instance.postgres.id}/upgrade"
  }
  description = "Browse these in AWS Console → CloudWatch → Log groups"
}
