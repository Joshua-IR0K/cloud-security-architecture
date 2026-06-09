# ============================================================
# cloudfront.tf — CloudFront Distribution (Phase 3 업데이트)
# ============================================================
#
# Phase 2 → Phase 3 변경:
#   1. Custom Domain (joshua-devsecops.com) 연결
#   2. ACM 인증서로 HTTPS 활성화
#   3. viewer_protocol_policy: redirect-to-https
#   4. Origin Protocol: https-only (ALB에 HTTPS 리스너 추가됨)
#
# ============================================================

resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "DMZ Architecture - Edge Defense with HTTPS"
  price_class         = "PriceClass_200"
  wait_for_deployment = true

  # Custom Domain
  aliases = [var.domain_name, "www.${var.domain_name}"]

  # WAF 연결
  web_acl_id = aws_wafv2_web_acl.main.arn

  # ── Origin: ALB ──────────────────────────────────────────
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only" # Phase 3: ALB에 HTTPS 리스너 추가됨
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    # ALB 직접 접근 차단용 비밀 헤더
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  # ── Default Cache Behavior ───────────────────────────────
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb-origin"
    compress         = true

    # Phase 3: HTTP → HTTPS 자동 리다이렉트
    viewer_protocol_policy = "redirect-to-https"

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ── Phase 3: ACM 인증서 (us-east-1) ─────────────────────
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"     # 추가 비용 없음
    minimum_protocol_version = "TLSv1.2_2021" # 최신 TLS만 허용
  }

  tags = {
    Name = "${var.project_name}-cloudfront"
  }
}
