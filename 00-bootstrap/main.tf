# ============================================================
# 00-bootstrap/main.tf — Remote State 저장소 (최초 1회 실행)
# ============================================================
#
# 왜 Bootstrap이 필요한가:
#   다른 스택들의 Terraform state를 S3에 저장하려면
#   그 S3 버킷이 먼저 존재해야 함 (닭과 달걀 문제)
#   이 스택만 로컬 state로 관리하고, 나머지는 S3 remote state 사용
#
# 이 스택은 절대 destroy하지 않음
#   → State 버킷이 삭제되면 모든 스택의 상태 정보가 유실됨
#
# 변경 이력:
#   - [개선-1] variable에 type, description 추가 (타입 검증 강화)
#   - [개선-3] DynamoDB PITR(Point-In-Time Recovery) 활성화
#   - [개선-4] S3 Server Access Logging 활성화 (감사 공백 방지)
#   - [개선-5] DynamoDB prevent_destroy 추가
#
# TODO: [개선-2] Phase 4A.5 — KMS CMK 도입 시 SSE를 aws:kms로 교체
#   현재: sse_algorithm = "AES256"  (AWS 관리 키)
#   예정: sse_algorithm = "aws:kms" (CMK, Phase 4A.5에서 생성할 키 ARN 사용)
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }

  # ⚠ Bootstrap만 로컬 state 사용 (의도적)
  # 이 파일의 state는 Git에 올리지 않고 로컬에서 관리
  # .gitignore에 terraform.tfstate, terraform.tfstate.backup 반드시 추가
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

# ============================================================
# Variables
# [개선-1] type과 description 추가
#   - type: 잘못된 타입 입력 시 plan 단계에서 즉시 오류 발생 (apply 전에 잡아냄)
#   - description: 코드를 처음 보는 사람도 각 변수의 용도를 즉시 파악 가능
# ============================================================

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

# ============================================================
# Data Source
# 현재 AWS 계정 ID를 동적으로 참조
# → S3 버킷명에 Account ID를 포함시켜 전 세계 고유성 보장
# ============================================================

data "aws_caller_identity" "current" {}

# ============================================================
# State 저장용 S3 버킷 (메인)
# ============================================================

resource "aws_s3_bucket" "terraform_state" {
  #checkov:skip=CKV_AWS_145:SSE-S3 적용 중. CMK 격상은 CI OIDC 권한 연쇄 설계 필요 — HARDENING_BACKLOG #1, Phase 4C 후 별도 증분
  bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  # ⚠ 절대 삭제 방지
  # terraform destroy 실행 시 이 리소스는 오류를 발생시키고 중단
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-terraform-state"
  }
}

# 버전 관리 활성화 — state 파일 변경 이력 보관
# state 손상 시 이전 정상 버전으로 롤백 가능
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 서버사이드 암호화 — state 파일 저장 시 자동 암호화
# TODO: [개선-2] Phase 4A.5에서 아래 설정으로 교체
#   sse_algorithm     = "aws:kms"
#   kms_master_key_id = <Phase 4A.5에서 생성할 CMK ARN>
#   bucket_key_enabled = true  (KMS API 호출 비용 절감)
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 퍼블릭 액세스 완전 차단 (4개 설정 모두 활성화)
# block_public_acls:       신규 ACL로 퍼블릭 권한 부여 차단
# ignore_public_acls:      기존 퍼블릭 ACL 무시
# block_public_policy:     버킷 정책으로 퍼블릭 허용 차단
# restrict_public_buckets: 기존 퍼블릭 버킷 정책 효력 제한
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# [개선-4] S3 Server Access Logging 활성화
#
# 목적: CloudTrail(02-security)이 배포되기 이전 구간,
#       즉 bootstrap → 01-network 프로비저닝 시점부터
#       state 파일에 대한 모든 접근(GetObject, PutObject 등)을 기록.
#       이로써 초기 인프라 구성 단계의 감사 공백(Blind Spot)을 원천 차단.
#
# 구성: state 버킷과 분리된 전용 로그 버킷 사용
#       (로그와 데이터를 같은 버킷에 두면 로그가 로그를 낳는 무한루프 발생)
# ============================================================

# 로그 저장 전용 버킷
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

# ACL 비활성화 (AWS 2023년 이후 최신 권고)
# BucketOwnerEnforced: ACL 자체를 완전히 비활성화
# (문서에서 제안한 BucketOwnerPreferred는 ACL을 일부 허용하는 레거시 방식)
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

# state 버킷 → 로그 버킷으로 액세스 로그 전송
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


# ============================================================
# DynamoDB Lock 테이블
# 동시에 두 명이 apply하는 것을 방지 (state locking)
# ============================================================

resource "aws_dynamodb_table" "terraform_lock" {
  #checkov:skip=CKV_AWS_119:Lock 테이블은 잠금 메타데이터(LockID)만 보관, 민감정보 없음. 기본 암호화로 충분 — CMK는 비용/복잡도 대비 효과 없음 (문서화된 결정)
  name         = "${var.project_name}-terraform-lock"
  billing_mode = "PAY_PER_REQUEST" # 온디맨드 — apply 시에만 사용, 사실상 무료
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # ============================================================
  # [개선-3] PITR(Point-In-Time Recovery) 활성화
  #
  # 목적: 잠금 테이블이 손상되거나 레코드가 오염된 경우
  #       최대 35일 이내의 임의 시점으로 복구 가능
  #       잠금 테이블 장애 → 모든 terraform apply 불가 → 서비스 중단
  #       PITR 비용: 테이블 크기 기준 (잠금 테이블은 레코드 수 극소 → 사실상 무료)
  # ============================================================
  point_in_time_recovery {
    enabled = true
  }

  # ============================================================
  # [개선-5] DynamoDB prevent_destroy 추가
  #
  # 기존: state 버킷(S3)에만 prevent_destroy 적용
  # 개선: 잠금 테이블도 동일하게 보호
  #
  # 잠금 테이블 삭제 시 영향:
  #   → State Locking 비활성화
  #   → 동시 apply 시 state 파일 손상 가능
  #   → 팀 환경에서 인프라 일관성 파괴
  # ============================================================
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-terraform-lock"
  }
}

# ============================================================
# 출력값
# ============================================================

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
