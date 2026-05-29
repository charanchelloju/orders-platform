resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "Postgres access from EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.cluster_security_group_id, module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

# ─── Master password — generated, never typed ──────────────────────────
resource "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"   # avoid chars that break JDBC URLs
}

# ─── Store master password in Secrets Manager ──────────────────────────
resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.project}/rds/master"
  description             = "RDS master password for ${var.project}"
  recovery_window_in_days = 0                  # 0 = immediate deletion (demo only)
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.db_master.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = aws_db_instance.postgres.db_name
  })
}

# ─── Per-service application passwords (also generated + stored) ───────
# These match the users created by infrastructure/postgres/init.sql
resource "random_password" "service_password" {
  for_each = toset(["order", "payment", "inventory"])

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "service_db" {
  for_each = toset(["order", "payment", "inventory"])

  name                    = "${var.project}/rds/${each.key}_service"
  description             = "DB credentials for ${each.key}-service"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "service_db" {
  for_each = toset(["order", "payment", "inventory"])

  secret_id = aws_secretsmanager_secret.service_db[each.key].id
  secret_string = jsonencode({
    SPRING_DATASOURCE_URL      = "jdbc:postgresql://${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${aws_db_instance.postgres.db_name}?currentSchema=${each.key == "inventory" ? "inventory" : "${each.key}s"}"
    SPRING_DATASOURCE_USERNAME = "${each.key}_service"
    SPRING_DATASOURCE_PASSWORD = random_password.service_password[each.key].result
  })
}

# Discover the latest available Postgres engine version in this region
# (avoids hard-coding versions that may not exist or have been deprecated)
data "aws_rds_engine_version" "postgres" {
  engine             = "postgres"
  preferred_versions = ["17.5", "17.6", "16.9", "16.10", "15.13", "15.14"]
}

# ─── RDS instance using the generated password ─────────────────────────
resource "aws_db_instance" "postgres" {
  identifier        = "${var.project}-postgres"
  engine            = "postgres"
  engine_version    = data.aws_rds_engine_version.postgres.version
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "orders_platform"
  username = "postgres"
  password = random_password.db_master.result    # generated, not from var

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  publicly_accessible    = false

  skip_final_snapshot     = true
  backup_retention_period = 0
  deletion_protection     = false

  # ─── CloudWatch integration ─────────────────────────────────────────────
  # Performance Insights = dashboard of top SQL by load, wait events
  performance_insights_enabled          = true
  performance_insights_retention_period = 7         # free tier

  # Enhanced monitoring = per-second OS metrics (CPU, IO, memory) to CloudWatch
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Export Postgres logs to CloudWatch:
  #   /aws/rds/instance/orders-platform-postgres/postgresql
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  lifecycle {
    ignore_changes = [password]    # password rotation handled by Secrets Manager
  }

  tags = {
    Project = var.project
  }
}

# ─── IAM role allowing RDS to write enhanced monitoring to CloudWatch ─────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
