resource "aws_sns_topic" "security_alerts" {
  name = "${var.project_name}-security-alerts"

  kms_master_key_id = aws_kms_key.logs.arn

  tags = {
    Name = "${var.project_name}-security-alerts"
  }
}

# 이메일 구독 — apply 후 이메일 인증 링크를 클릭해야 활성화됨
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# GuardDuty Finding → SNS (Medium 이상)
# GuardDuty 심각도: Low(1-3.9), Medium(4-6.9), High(7-10)
# Medium 이상만 알림 → 노이즈 감소
resource "aws_cloudwatch_event_rule" "guardduty_alert" {
  name        = "${var.project_name}-guardduty-medium-high"
  description = "GuardDuty findings with severity Medium or higher"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [
        { numeric = [">=", 4] }
      ]
    }
  })

  tags = {
    Name = "${var.project_name}-guardduty-alert"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_alert.name
  target_id = "guardduty-to-sns"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      title       = "$.detail.title"
      description = "$.detail.description"
      region      = "$.detail.region"
      account     = "$.detail.accountId"
      time        = "$.time"
    }
    input_template = jsonencode("🚨 [GuardDuty] <severity> Severity Finding\n\nType: <type>\nTitle: <title>\nDescription: <description>\nRegion: <region>\nAccount: <account>\nTime: <time>\n\n→ AWS Console에서 GuardDuty Findings를 확인하세요.")
  }
}

# Security Hub Finding → SNS (Critical/High)
resource "aws_cloudwatch_event_rule" "securityhub_alert" {
  name        = "${var.project_name}-securityhub-critical-high"
  description = "Security Hub findings with CRITICAL or HIGH severity"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = {
          Label = ["CRITICAL", "HIGH"]
        }
        Workflow = {
          Status = ["NEW"]
        }
      }
    }
  })

  tags = {
    Name = "${var.project_name}-securityhub-alert"
  }
}

resource "aws_cloudwatch_event_target" "securityhub_to_sns" {
  rule      = aws_cloudwatch_event_rule.securityhub_alert.name
  target_id = "securityhub-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_cloudwatch_event_rule" "inspector_alert" {
  name        = "${var.project_name}-inspector-findings"
  description = "Inspector vulnerability findings - HIGH and CRITICAL"

  event_pattern = jsonencode({
    source      = ["aws.inspector2"]
    detail-type = ["Inspector2 Finding"]
    detail = {
      severity = ["HIGH", "CRITICAL"]
    }
  })

  tags = {
    Name = "${var.project_name}-inspector-alert"
  }
}

resource "aws_cloudwatch_event_target" "inspector_to_sns" {
  rule      = aws_cloudwatch_event_rule.inspector_alert.name
  target_id = "inspector-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# SNS Topic Policy (EventBridge가 SNS에 발행할 수 있도록)
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}
