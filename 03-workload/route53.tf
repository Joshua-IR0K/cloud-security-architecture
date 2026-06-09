# ============================================================
# route53.tf — DNS 레코드 관리
# ============================================================
#
# Route 53에 추가되는 레코드:
#   1. ACM 인증서 DNS 검증용 CNAME (자동)
#   2. joshua-devsecops.com → CloudFront Alias (A 레코드)
#
# 왜 Alias인가?
#   일반 CNAME은 루트 도메인(@)에 사용 불가 (DNS 표준 제약)
#   Route 53 Alias는 AWS 전용 기능으로 루트 도메인에도 사용 가능
#   + Alias 쿼리는 Route 53 비용이 무료
#
# ============================================================

# ── 기존 Hosted Zone 조회 ─────────────────────────────────
# Route 53에서 도메인 등록 시 자동 생성된 Hosted Zone을 참조
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ── ACM 인증서 DNS 검증 레코드 ────────────────────────────
# 두 인증서(CloudFront용 + ALB용)의 검증 레코드를 통합
# 같은 도메인이므로 검증 레코드가 동일 → 중복 제거
locals {
  # CloudFront 인증서와 ALB 인증서의 검증 레코드를 합침
  cert_validation_options = merge(
    {
      for dvo in aws_acm_certificate.cloudfront.domain_validation_options :
      dvo.domain_name => {
        name   = dvo.resource_record_name
        record = dvo.resource_record_value
        type   = dvo.resource_record_type
      }
    },
    {
      for dvo in aws_acm_certificate.alb.domain_validation_options :
      dvo.domain_name => {
        name   = dvo.resource_record_name
        record = dvo.resource_record_value
        type   = dvo.resource_record_type
      }
    }
  )
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.cert_validation_options

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]

  allow_overwrite = true
}

# ── 도메인 → CloudFront Alias ─────────────────────────────
# joshua-devsecops.com → CloudFront Distribution
# 사용자가 도메인을 입력하면 CloudFront로 라우팅됨
resource "aws_route53_record" "cloudfront_alias" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── www 서브도메인도 CloudFront로 라우팅 ───────────────────
resource "aws_route53_record" "www_alias" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
