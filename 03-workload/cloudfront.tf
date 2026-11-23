# X-Origin-Verify 값은 origin_verify.tf 의 2슬롯에서 온다 (무중단 교체 절차 포함)

resource "aws_cloudfront_distribution" "main" {
  #checkov:skip=CKV_AWS_374:지역 제한 미적용 — 글로벌 포트폴리오 접근성 요구 + VPN 우회 가능한 약한 통제로 판단
  #checkov:skip=CKV_AWS_310:Origin failover 미구성 — 단일 ALB 오리진 설계, 멀티 오리진은 과잉 설계
  #checkov:skip=CKV_AWS_305:default root object 미설정 — S3 정적 사이트용 체크, 본 구성은 동적 오리진(nginx가 / 서빙)
  #checkov:skip=CKV_AWS_86:액세스 로깅 보류 — Datadog SIEM(Phase 4A-3) 수집 대상 설계 시 일괄 결정 (HARDENING_BACKLOG)
  #checkov:skip=CKV2_AWS_32:Checkov 오탐(공식 이슈 #2873,#5597) — AWS 관리형 SecurityHeadersPolicy(67f7725c) 적용됨. 그래프 체크가 관리형 정책 ID 참조를 인식 못 하는 한계
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "DMZ Architecture - Edge Defense with HTTPS"
  price_class         = "PriceClass_200"
  wait_for_deployment = true

  aliases = [var.domain_name, "www.${var.domain_name}"]

  web_acl_id = aws_wafv2_web_acl.main.arn

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # Phase 3: ALB에 HTTPS 리스너 추가됨
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    # ALB 직접 접근 차단용 비밀 헤더 — 지금 활성인 슬롯 값 (origin_verify.tf)
    custom_header {
      name  = "X-Origin-Verify"
      value = local.origin_verify_sent
    }
  }

  # Default Cache Behavior
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-origin"
    compress               = true

    viewer_protocol_policy = "redirect-to-https"

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"

    # AWS 관리형 SecurityHeadersPolicy — HSTS, X-Content-Type-Options,
    # X-Frame-Options, Referrer-Policy 등 보안 응답 헤더 자동 적용
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ACM 인증서 (us-east-1)
  viewer_certificate {
    acm_certificate_arn      = local.cloudfront_cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.project_name}-cloudfront"
  }
}
