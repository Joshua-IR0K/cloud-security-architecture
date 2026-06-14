# ============================================================
# cloudtrail.tf — AWS CloudTrail (API 감사 로그)
# ============================================================
#
# 저장소 원칙 (멘토 권장):
#   ✅ S3 직접 저장 — 원본 로그의 유일한 저장소
#   ✗ CloudWatch Logs 전송 금지 — 대용량 API 로그를 CW에 쌓으면
#     비용 폭주 (Ingestion $0.50/GB + Storage $0.03/GB/월)
#
# CloudWatch를 쓰지 않아도 실시간 탐지가 가능한 이유:
#   - GuardDuty가 CloudTrail 이벤트를 직접 분석 (CW 불필요)
#   - EventBridge가 CloudTrail API 이벤트를 직접 수신 가능
#     (aws.cloudtrail → EventBridge Rule → SNS/Lambda)
#   - S3에 적재된 로그는 Athena로 SQL 분석 가능
#
# 즉, CW 없이도 "실시간 탐지 + 사후 분석" 모두 커버됨
#
# 비용:
#   - 관리 이벤트 첫 번째 트레일: 무료
#   - S3 저장: 로그 양에 따라 (테스트 수준 $1 미만/월)
#
# ============================================================

# ── CloudTrail 로그 저장용 S3 버킷 ────────────────────────
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-cloudtrail-logs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail → S3 쓰기 권한
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-trail"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-trail"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

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


# ── CloudTrail 트레일 ─────────────────────────────────────
resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV_AWS_252:SNS 미연결 — EventBridge가 CloudTrail 이벤트를 직접 수신하는 구조로 중복 경로 불필요
  name           = "${var.project_name}-trail"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  # 관리 이벤트: 모든 AWS API 호출 기록
  include_global_service_events = true # IAM 등 글로벌 서비스 포함
  is_multi_region_trail         = true # 모든 리전의 이벤트 수집
  enable_logging                = true

  # ✗ CloudWatch Logs 전송 없음 — S3가 유일한 저장소
  #   GuardDuty와 EventBridge가 CloudTrail 이벤트를 직접 수신하므로
  #   CW Logs 없이도 실시간 탐지/알림이 가능함

  # 로그 파일 무결성 검증 — 포렌식 필수
  # 다이제스트 파일로 로그 변조 여부를 검증 가능
  enable_log_file_validation = true

  kms_key_id = aws_kms_key.logs.arn   # ← 이 줄 추가 (CKV_AWS_35)

  tags = {
    Name = "${var.project_name}-trail"
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ──────────────────────────────────────────────────────────
# CloudWatch를 제거한 대신 실시간 탐지는 이렇게 동작:
#
# 1. GuardDuty: CloudTrail 관리 이벤트를 직접 분석
#    → UnauthorizedAccess, Recon 등 Finding 자동 생성
#
# 2. EventBridge: CloudTrail API 호출 이벤트를 직접 수신 가능
#    예) IAM 정책 변경 시 즉시 알림:
#    {
#      "source": ["aws.iam"],
#      "detail-type": ["AWS API Call via CloudTrail"],
#      "detail": {
#        "eventName": ["PutUserPolicy", "AttachRolePolicy"]
#      }
#    }
#
# 3. Athena: S3에 저장된 원본 로그를 SQL로 사후 분석
#    → 사고 타임라인 재구성, API 호출 이력 추적
# ──────────────────────────────────────────────────────────
