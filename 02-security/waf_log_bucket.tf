# SSE-S3 — 버킷이 us-east-1(CloudFront WAF 제약)이라 서울 리전 logs 키를 쓸 수 없고, 버킷 하나를 위해 별도 키를 두지 않음

resource "aws_s3_bucket" "waf_logs" {
  #checkov:skip=CKV_AWS_145:us-east-1 리전 제약 — ap-northeast-2의 logs CMK 사용 불가, 단일 버킷용 별도 CMK는 과잉 운영 부담 (문서화된 결정)
  provider = aws.us_east_1

  bucket        = "aws-waf-logs-${var.project_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.project_name}-waf-logs" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  provider                = aws.us_east_1
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버저닝 — 로그 변조 방어 (CKV_AWS_21 대응)
resource "aws_s3_bucket_versioning" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 라이프사이클 — FinOps 티어링 (CKV2_AWS_61 대응)
resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id

  rule {
    id     = "log-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
