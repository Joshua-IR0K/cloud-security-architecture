resource "aws_securityhub_account" "main" {
  auto_enable_controls = true
}

# 보안 표준 활성화
# ⚠ Config Recorder가 활성화된 후에 표준을 구독해야
#    보안 점수가 정상 산출됨

# CIS AWS Foundations Benchmark v1.4.0
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

# AWS Foundational Security Best Practices (FSBP)
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

# GuardDuty → Security Hub 통합
resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/guardduty"

  depends_on = [aws_securityhub_account.main]
}

# Inspector → Security Hub 통합
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/inspector"

  depends_on = [aws_securityhub_account.main]
}

resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"] # EC2 취약점 + ECR 이미지 스캔

  depends_on = [aws_securityhub_account.main]
}
