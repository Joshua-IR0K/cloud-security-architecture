resource "aws_wafv2_web_acl" "main" {
  provider = aws.us_east_1

  name        = "${var.project_name}-waf-acl"
  description = "DMZ Edge Defense - CloudFront WAF"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit"
    }
  }

  rule {
    name     = "ip-reputation"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-ip-reputation"
    }
  }

  rule {
    name     = "anonymous-ip"
    priority = 2

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-anonymous-ip"
    }
  }

  rule {
    name     = "sqli-protection"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-sqli"
    }
  }

  rule {
    name     = "common-rules"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
    }
  }

  rule {
    name     = "linux-protection"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-linux-rules"
    }
  }

  # Log4Shell(CVE-2021-44228) 등 알려진 악성 입력 차단
  # 위협 기반 설계: JNDI lookup 패턴 등 명시적 방어 (CKV_AWS_192 대응)
  rule {
    name     = "known-bad-inputs"
    priority = 6

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-known-bad-inputs"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf-acl"
  }

  tags = {
    Name = "${var.project_name}-waf-acl"
  }
}

# WAF 로깅 — S3 버킷은 02-security 스택에서 관리
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  provider = aws.us_east_1

  log_destination_configs = [local.waf_log_bucket_arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}
