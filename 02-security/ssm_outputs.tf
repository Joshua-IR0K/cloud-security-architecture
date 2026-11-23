# 03의 WAF 로깅 설정이 읽는다.
resource "aws_ssm_parameter" "waf_log_bucket_arn" {
  name  = "/${var.project_name}/security/waf_log_bucket_arn"
  type  = "String"
  value = aws_s3_bucket.waf_logs.arn

  tags = { Name = "${var.project_name}-waf-log-bucket-arn" }
}

resource "aws_ssm_parameter" "sns_topic_arn" {
  name  = "/${var.project_name}/security/sns_topic_arn"
  type  = "String"
  value = aws_sns_topic.security_alerts.arn

  tags = { Name = "${var.project_name}-sns-topic-arn" }
}

resource "aws_ssm_parameter" "guardduty_detector_id" {
  name  = "/${var.project_name}/security/guardduty_detector_id"
  type  = "String"
  value = aws_guardduty_detector.main.id

  tags = { Name = "${var.project_name}-guardduty-detector-id" }
}

# 03(EC2)·04(노드)가 볼륨 암호화에 읽는다.
resource "aws_ssm_parameter" "ebs_kms_key_arn" {
  name  = "/${var.project_name}/security/ebs_kms_key_arn"
  type  = "String"
  value = aws_kms_key.ebs.arn

  tags = { Name = "${var.project_name}-ebs-kms-key-arn" }
}

# 03이 apply 때 이 ARN으로 값을 읽어서 ALB 인증 설정에 넣는다.
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
