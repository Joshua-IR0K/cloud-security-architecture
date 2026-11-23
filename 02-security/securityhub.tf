resource "aws_securityhub_account" "main" {
  auto_enable_controls = true
}

# Config 기록이 켜진 다음에 구독해야 보안 점수가 제대로 나온다.

resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [
    aws_securityhub_account.main,
    aws_config_configuration_recorder_status.main
  ]
}

resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/guardduty"

  depends_on = [aws_securityhub_account.main]
}

resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.aws_region}::product/aws/inspector"

  depends_on = [aws_securityhub_account.main]
}

resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"] # EC2 취약점 + ECR 이미지 스캔

  depends_on = [aws_securityhub_account.main]
}
