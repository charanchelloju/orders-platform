# ─── Java Lambda: archive-orders (cron-driven) ────────────────────────────
# Weekly job that moves orders older than 6 months from Postgres → S3.
# Written in Java 21, packaged via maven-shade-plugin as a fat JAR.
# Cold start: ~5 sec on first invoke (acceptable for a cron with no user waiting).
# SnapStart cuts that to <1 sec; enabled below.

# ─── IAM role for the Lambda ──────────────────────────────────────────────
resource "aws_iam_role" "lambda_jobs" {
  name = "${var.project}-lambda-jobs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project }
}

# Write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_jobs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach VPC permissions so Lambda can create ENIs in our private subnets
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_jobs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Least-privilege policy: only the secret + archive bucket
resource "aws_iam_role_policy" "lambda_custom" {
  name = "lambda-jobs-custom"
  role = aws_iam_role.lambda_jobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_master.arn
      },
      {
        Sid      = "WriteArchiveBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      }
    ]
  })
}

# ─── Security group: Lambda → RDS + outbound to AWS APIs via NAT ─────────
resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda"
  description = "Lambda jobs egress (S3/Secrets via NAT, RDS via VPC)"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.project }
}

# Allow Lambda → RDS:5432
resource "aws_security_group_rule" "rds_from_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda.id
  security_group_id        = aws_security_group.rds.id
  description              = "Lambda jobs read/write RDS"
}

# ─── Lambda function: archive-orders ──────────────────────────────────────
# Lambda's Java runtime accepts JARs directly — no zip wrapping needed.
# Wrapping a JAR inside a zip causes "Class not found" because the runtime
# looks for classes at the top level of the deployment package.

locals {
  archive_orders_jar = "${path.module}/../services/lambdas/archive-orders/target/archive-orders.jar"
}

resource "aws_lambda_function" "archive_orders" {
  function_name    = "${var.project}-archive-orders"
  role             = aws_iam_role.lambda_jobs.arn
  filename         = local.archive_orders_jar
  source_code_hash = filebase64sha256(local.archive_orders_jar)

  handler     = "com.orders.lambda.ArchiveOrdersHandler::handleRequest"
  runtime     = "java17"
  memory_size = 1024 # MB — more memory => more CPU => faster JVM init
  timeout     = 300  # 5 min — archival batch can be slow

  # SnapStart drops Java cold start from ~5 sec to <1 sec
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST           = aws_db_instance.postgres.address
      DB_NAME           = aws_db_instance.postgres.db_name
      DB_SECRET_ARN     = aws_secretsmanager_secret.db_master.arn
      ARCHIVE_BUCKET    = aws_s3_bucket.archive.id
      JAVA_TOOL_OPTIONS = "-XX:+TieredCompilation -XX:TieredStopAtLevel=1"
    }
  }

  tags = { Project = var.project, Job = "archive-orders" }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]
}

output "archive_orders_function_name" {
  value = aws_lambda_function.archive_orders.function_name
}
