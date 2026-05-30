# ─── S3 archive bucket for Lambda archival job ────────────────────────────
# Holds orders moved out of Postgres. Transitions to Glacier at 90 days,
# Deep Archive at 365 days for long-term cheap storage.

data "aws_caller_identity" "lambda_account" {}

resource "aws_s3_bucket" "archive" {
  bucket = "${var.project}-archive-${data.aws_caller_identity.lambda_account.account_id}"
}

# Versioning protects against accidental delete / overwrite
resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration { status = "Enabled" }
}

# Encrypt at rest (AES256, no KMS key cost)
resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Block all public access (contains customer data)
resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Lifecycle: standard → Glacier → Deep Archive
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    id     = "to-glacier-then-deep-archive"
    status = "Enabled"
    filter {} # whole bucket
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

output "archive_bucket" {
  value       = aws_s3_bucket.archive.id
  description = "S3 bucket holding archived orders"
}
