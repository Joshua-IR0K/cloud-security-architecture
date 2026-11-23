terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "bootstrap"
    }
  }
}

variable "aws_region" {
  description = "AWS 리소스를 배포할 리전. 기본값: 서울 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 인증에 사용할 프로파일명 (~/.aws/config 기준)"
  type        = string
  default     = "devsecops-admin"
}

variable "project_name" {
  description = "모든 리소스 이름의 prefix로 사용되는 프로젝트 식별자"
  type        = string
  default     = "devsecops-project"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "terraform_state" {
  #checkov:skip=CKV_AWS_145:SSE-S3 적용 중. CMK 격상은 CI OIDC 권한 연쇄 설계 필요 — HARDENING_BACKLOG #1, Phase 4C 후 별도 증분
  bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 목적: CloudTrail(02-security)이 배포되기 이전 구간,
#       즉 bootstrap → 01-network 프로비저닝 시점부터
#       state 파일에 대한 모든 접근(GetObject, PutObject 등)을 기록.
#       이로써 초기 인프라 구성 단계의 감사 공백(Blind Spot)을 원천 차단.
#
# 구성: state 버킷과 분리된 전용 로그 버킷 사용
#       (로그와 데이터를 같은 버킷에 두면 로그가 로그를 낳는 무한루프 발생)

resource "aws_s3_bucket" "terraform_state_log" {
  #checkov:skip=CKV_AWS_145:SSE-S3 적용 중. 로그 버킷 CMK는 state 버킷 KMS 증분과 함께 처리 — HARDENING_BACKLOG #1
  bucket = "${var.project_name}-tf-state-log-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-terraform-state-log"
    Purpose = "S3 Server Access Log Storage"
  }
}

resource "aws_s3_bucket_ownership_controls" "terraform_state_log" {
  bucket = aws_s3_bucket.terraform_state_log.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 로그 버킷도 state 버킷과 동일한 보안 기준 적용
# (로그 버킷이 더 약하면 로그 버킷을 통한 우회 공격 경로 발생)
resource "aws_s3_bucket_public_access_block" "terraform_state_log" {
  bucket = aws_s3_bucket.terraform_state_log.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_log" {
  bucket = aws_s3_bucket.terraform_state_log.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "terraform_state_log" {
  bucket = aws_s3_bucket.terraform_state_log.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 로그 버킷 라이프사이클 — 액세스 로그는 무한 축적 방지
# (state 버킷과 달리 로그는 만료시켜도 무방 — 오래된 액세스 로그는 가치 낮음)
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state_log" {
  bucket = aws_s3_bucket.terraform_state_log.id

  rule {
    id     = "log-housekeeping"
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

resource "aws_s3_bucket_logging" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  target_bucket = aws_s3_bucket.terraform_state_log.id
  target_prefix = "state-access-logs/"

  # logging 리소스는 ownership_controls 설정 이후에 생성되어야 함
  depends_on = [aws_s3_bucket_ownership_controls.terraform_state_log]
}

# state 라이프사이클 — 현재 state는 절대 만료시키지 않음. 구버전만 정리
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "state-housekeeping"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90   # 90일치 state 이력 보관 (롤백 대비)
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_dynamodb_table" "terraform_lock" {
  #checkov:skip=CKV_AWS_119:Lock 테이블은 잠금 메타데이터(LockID)만 보관, 민감정보 없음. 기본 암호화로 충분 — CMK는 비용/복잡도 대비 효과 없음 (문서화된 결정)
  name         = "${var.project_name}-terraform-lock"
  billing_mode = "PAY_PER_REQUEST" # 온디맨드 — apply 시에만 사용, 사실상 무료
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-terraform-lock"
  }
}

output "state_bucket_name" {
  description = "다른 스택의 backend.tf에서 사용할 S3 State 버킷 이름"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_log_bucket_name" {
  description = "State 버킷 액세스 로그가 저장되는 로그 전용 버킷 이름"
  value       = aws_s3_bucket.terraform_state_log.bucket
}

output "lock_table_name" {
  description = "다른 스택의 backend.tf에서 사용할 DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.terraform_lock.name
}

output "setup_guide" {
  value = <<-EOT

    ╔═══════════════════════════════════════════════════════════╗
    ║  Bootstrap 완료!                                          ║
    ║                                                           ║
    ║  다른 스택의 backend.tf에서 아래 값을 사용하세요:          ║
    ║                                                           ║
    ║  bucket         = "${aws_s3_bucket.terraform_state.bucket}"
    ║  dynamodb_table = "${aws_dynamodb_table.terraform_lock.name}"
    ║  region         = "${var.aws_region}"
    ║                                                           ║
    ║  State 액세스 로그 저장 위치:                              ║
    ║  log_bucket     = "${aws_s3_bucket.terraform_state_log.bucket}"
    ║                                                           ║
    ║  ⚠ 이 스택은 절대 destroy하지 마세요!                     ║
    ║  ⚠ terraform.tfstate를 반드시 .gitignore에 추가하세요!    ║
    ╚═══════════════════════════════════════════════════════════╝

  EOT
}
