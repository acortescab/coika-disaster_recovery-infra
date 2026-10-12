# DR-region bucket for the Terraform state of the auth service (coika-auth_service-infra).
# The failover build runs that stack in this region, so its state must live here and not in
# the primary region, which may be the one that is down. It is an independent state (key
# `regions/<region>/terraform.tfstate`), not a replica of the primary one.

resource "aws_s3_bucket" "service_state" {
  bucket           = var.service_state_bucket
  bucket_namespace = "account-regional"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "service_state" {
  bucket = aws_s3_bucket.service_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "service_state" {
  bucket = aws_s3_bucket.service_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "service_state" {
  bucket = aws_s3_bucket.service_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "service_state" {
  bucket = aws_s3_bucket.service_state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.service_state]
}
