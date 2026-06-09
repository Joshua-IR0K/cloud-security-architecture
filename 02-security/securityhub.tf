# ============================================================
# securityhub.tf — AWS Security Hub + Inspector + Finding 통합
# ============================================================
#
# Security Hub = 위협 통합 허브 + CSPM
#
# 역할:
#   1. GuardDuty, Inspector, 외부 도구의 Finding을 통합 수집
#   2. CIS Benchmark / FSBP 보안 표준으로 인프라 준수 평가
#   3. 보안 점수(Security Score) 산출
#   4. 멀티 계정 시 Audit 계정으로 Finding 중앙 집중화 (Phase 5)
#
# Config 의존성:
#   Security Hub의 보안 표준 평가는 AWS Config가 기록하는
#   리소스 상태를 기반으로 동작함. Config Recorder가 활성화되지
#   않으면 보안 점수가 0%로 유지됨.
#   → 표준 구독은 Config Recorder 활성화 이후에 생성되어야 함
#
# Finding 흐름:
#   GuardDuty Finding  ─┐
#   Inspector Finding   ─┼─→ Security Hub ─→ EventBridge ─→ SNS/대응
#   Config Rules        ─┘    (통합 뷰)
#   (Phase 5: Prowler 등 외부 도구)
#
# 비용:
#   - Security Hub: 30일 무료 → 이후 Finding당 과금 ($1~3/월)
#   - Inspector: 15일 무료 → 이후 스캔당 과금 ($1~2/월)
#
# ============================================================

# ── Security Hub 활성화 ───────────────────────────────────
resource "aws_securityhub_account" "main" {
  auto_enable_controls = true
}

# ── 보안 표준 활성화 ──────────────────────────────────────
# ⚠ Config Recorder가 활성화된 후에 표준을 구독해야
#    보안 점수가 정상 산출됨

# CIS AWS Foundations Benchmark v1.4.0
# → IAM, 로깅, 모니터링, 네트워킹 등 기본 보안 설정 평가
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

# AWS Foundational Security Best Practices (FSBP)
# → AWS 서비스별 보안 모범 사례 평가
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

# ── GuardDuty → Security Hub 통합 ────────────────────────
resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/guardduty"

  depends_on = [aws_securityhub_account.main]
}

# ── Inspector → Security Hub 통합 ────────────────────────
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/inspector"

  depends_on = [aws_securityhub_account.main]
}

# ── Amazon Inspector 활성화 ───────────────────────────────
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"] # EC2 취약점 + ECR 이미지 스캔

  depends_on = [aws_securityhub_account.main]
}

# ──────────────────────────────────────────────────────────
# [Phase 5: 멀티 계정 확장 시]
#
# Audit 계정의 Security Hub를 Administrator로 지정하고,
# 모든 Member 계정의 Finding을 중앙 수집:
#
# resource "aws_securityhub_organization_admin_account" "main" {
#   admin_account_id = var.audit_account_id
# }
#
# resource "aws_securityhub_member" "workload" {
#   account_id = var.workload_account_id
#   email      = "workload@joshua-devsecops.com"
# }
#
# 이렇게 하면 Audit 계정 하나에서 모든 계정의
# 보안 점수 + Finding을 통합 조회 가능
# ──────────────────────────────────────────────────────────
