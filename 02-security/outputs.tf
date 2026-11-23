output "cloudtrail_s3_bucket" {
  description = "CloudTrail 로그 S3 버킷"
  value       = aws_s3_bucket.cloudtrail.bucket
}

output "guardduty_detector_id" {
  description = "GuardDuty Detector ID"
  value       = aws_guardduty_detector.main.id
}

output "flow_logs_s3_bucket" {
  description = "VPC Flow Logs S3 버킷"
  value       = aws_s3_bucket.flow_logs.bucket
}

output "config_s3_bucket" {
  description = "AWS Config S3 버킷"
  value       = aws_s3_bucket.config.bucket
}

output "waf_log_bucket" {
  description = "WAF 로그 S3 버킷"
  value       = aws_s3_bucket.waf_logs.bucket
}

output "sns_topic_arn" {
  description = "보안 알림 SNS Topic ARN"
  value       = aws_sns_topic.security_alerts.arn
}
