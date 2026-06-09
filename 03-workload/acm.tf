# ============================================================
# acm.tf — TLS 인증서 (ACM)
# ============================================================
#
# 인증서가 2개 필요한 이유:
#
#   1. CloudFront용: 반드시 us-east-1에서 발급 (AWS 제약)
#      → CloudFront가 HTTPS로 사용자 요청을 받을 때 사용
#
#   2. ALB용: ALB가 있는 리전(ap-northeast-2)에서 발급
#      → ALB HTTPS 리스너 + Okta OIDC 인증에 필요
#      → OIDC는 HTTPS에서만 동작
#
# 검증 방식: DNS 검증 (Route 53에 자동으로 CNAME 레코드 추가)
#   이메일 검증보다 빠르고 자동 갱신도 지원됨
#
# ============================================================

# ── CloudFront용 인증서 (us-east-1) ───────────────────────
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  # 와일드카드 포함하면 서브도메인도 커버 가능
  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    # 새 인증서를 먼저 생성한 후 기존 것을 삭제 (다운타임 방지)
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-cloudfront-cert"
  }
}

# ── ALB용 인증서 (서울 리전) ──────────────────────────────
resource "aws_acm_certificate" "alb" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-alb-cert"
  }
}

# ── 인증서 DNS 검증 완료 대기 ─────────────────────────────
# Route 53에 검증용 CNAME이 추가된 후, ACM이 이를 확인하면 인증서 활성화
# 보통 2~5분 소요

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
