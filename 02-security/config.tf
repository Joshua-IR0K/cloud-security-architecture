# ============================================================
# config.tf — AWS Config (리소스 구성 기록)
# ============================================================
#
# 역할: AWS 리소스의 구성 상태를 지속적으로 기록하고 변경 이력을 추적
#
# 왜 필요한가:
#   1. Security Hub 연동 — CIS/FSBP 보안 표준 평가의 데이터 소스
#      Config 없이는 Security Hub 보안 점수가 0%로 유지됨
#   2. 리소스 변경 추적 — "SG 규칙이 언제, 누구에 의해 변경되었는가?"
#      CloudTrail은 API 호출을 기록하고, Config는 그 결과로
#      리소스 상태가 어떻게 바뀌었는지를 기록
#   3. 컴플라이언스 — ISMS-P, SOC2 등에서 요구하는
#      리소스 구성 감사 추적의 근거
#
# CloudTrail vs Config 차이:
#   CloudTrail: "누가 언제 어떤 API를 호출했는가" (행위 기록)
#   Config:     "그 결과 리소스가 어떤 상태로 바뀌었는가" (상태 기록)
#   → 둘이 합쳐져야 완전한 감사 추적이 가능
#
# 저장소 원칙:
#   ✅ S3 직접 저장 (원본 구성 스냅샷/이력)
#   ✗ CloudWatch 사용 안 함 (동일 원칙 적용)
#
# 비용:
#   - 구성 항목(Configuration Item)당 $0.003
#   - 테스트 수준 월 $1~3
#
# ============================================================

# ── Config 기록용 S3 버킷 ─────────────────────────────────
resource "aws_s3_bucket" "config" {
  bucket        = "${var.project_name}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-config-logs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Config → S3 쓰기 권한
resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"     = "bucket-owner-full-control"
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ── Config IAM Role ───────────────────────────────────────
# Config가 리소스 상태를 읽고 S3에 기록하기 위한 역할
resource "aws_iam_role" "config" {
  name = "${var.project_name}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-config-role"
  }
}

# AWS 관리형 정책: Config가 리소스를 읽을 수 있는 권한
resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Config → S3 쓰기 권한 (인라인 정책)
resource "aws_iam_role_policy" "config_s3" {
  name = "${var.project_name}-config-s3-policy"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          aws_s3_bucket.config.arn,
          "${aws_s3_bucket.config.arn}/*"
        ]
      }
    ]
  })
}

# ── Config Recorder ───────────────────────────────────────
# 모든 리소스 유형의 구성 변경을 기록
resource "aws_config_configuration_recorder" "main" {
  name     = "${var.project_name}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true  # 모든 지원 리소스 유형 기록
    include_global_resource_types = true  # IAM 등 글로벌 리소스 포함
  }

  recording_mode {
    recording_frequency = "CONTINUOUS" # 변경 발생 시 즉시 기록
  }
}

# ── Config Delivery Channel ───────────────────────────────
# 기록된 구성 정보를 S3로 전달
resource "aws_config_delivery_channel" "main" {
  name           = "${var.project_name}-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  # 구성 스냅샷 전달 주기
  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours" # 6시간마다 전체 스냅샷
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# ── Config Recorder 시작 ──────────────────────────────────
# Recorder와 Delivery Channel이 모두 준비된 후 기록 시작
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}
