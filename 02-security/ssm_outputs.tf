# WAF 로그 S3 버킷 ARN (워크로드의 WAF 로깅 설정에 필요)
resource "aws_ssm_parameter" "waf_log_bucket_arn" {
  name  = "/${var.project_name}/security/waf_log_bucket_arn"
  type  = "String"
  value = aws_s3_bucket.waf_logs.arn

  tags = { Name = "${var.project_name}-waf-log-bucket-arn" }
}

# SNS Topic ARN (워크로드에서도 알림 가능하도록)
resource "aws_ssm_parameter" "sns_topic_arn" {
  name  = "/${var.project_name}/security/sns_topic_arn"
  type  = "String"
  value = aws_sns_topic.security_alerts.arn

  tags = { Name = "${var.project_name}-sns-topic-arn" }
}

# GuardDuty Detector ID (워크로드에서 EKS Protection 등 확장 시)
resource "aws_ssm_parameter" "guardduty_detector_id" {
  name  = "/${var.project_name}/security/guardduty_detector_id"
  type  = "String"
  value = aws_guardduty_detector.main.id

  tags = { Name = "${var.project_name}-guardduty-detector-id" }
}

# EBS 암호화 KMS 키 ARN (워크로드 EC2/EKS 볼륨 암호화용)
resource "aws_ssm_parameter" "ebs_kms_key_arn" {
  name  = "/${var.project_name}/security/ebs_kms_key_arn"
  type  = "String"
  value = aws_kms_key.ebs.arn

  tags = { Name = "${var.project_name}-ebs-kms-key-arn" }
}

# Okta OIDC 시크릿 ARN (워크로드 ALB가 런타임에 읽음)
resource "aws_ssm_parameter" "okta_secret_arn" {
  name  = "/${var.project_name}/security/okta_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.okta_oidc.arn

  tags = { Name = "${var.project_name}-okta-secret-arn" }
}

resource "aws_ssm_parameter" "secrets_kms_key_arn" {
  name  = "/${var.project_name}/security/secrets_kms_key_arn"
  type  = "String"
  value = aws_kms_key.secrets.arn

  tags = { Name = "${var.project_name}-secrets_kms_key_arn" }
}
