# ============================================================
# 02-security/waf_log_bucket.tf — WAF 로그 저장용 S3 버킷
# ============================================================
# WAF WebACL 자체는 03-workload에 배치 (고비용, 임시)
# 로그 버킷은 영속 보안 스택에 보관 (워크로드 destroy 후에도 로그 유지)
#
# ⚠ KMS 암호화 미적용 (의도적 결정):
#   KMS 키는 리전별 리소스. logs CMK는 ap-northeast-2에 있는데
#   이 버킷은 us-east-1(CloudFront WAF 제약)에 있어 키를 공유 불가.
#   단일 버킷을 위해 us-east-1 전용 CMK를 따로 관리하는 것은
#   과한 운영 부담이라 판단 → SSE-S3(AES256) 유지.
#   프로덕션에서 규제 요구가 있으면 us-east-1 전용 CMK 추가 가능.
# ============================================================

resource "aws_s3_bucket" "waf_logs" {
  #checkov:skip=CKV_AWS_145:us-east-1 리전 제약 — ap-northeast-2의 logs CMK 사용 불가, 단일 버킷용 별도 CMK는 과잉 운영 부담 (문서화된 결정)
  provider = aws.us_east_1

  bucket        = "aws-waf-logs-${var.project_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = { Name = "${var.project_name}-waf-logs" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
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
