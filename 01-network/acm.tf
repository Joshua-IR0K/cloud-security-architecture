# ============================================================
# 01-network/acm.tf — TLS 인증서 (영속 자산)
# ============================================================
#
# [이동 이력] 03-workload → 01-network (리팩토링)
#   근거:
#   1. ACM 퍼블릭 인증서는 무료 → "01-network는 무료 리소스만" 원칙 부합
#   2. workload destroy마다 인증서 삭제 → 재apply 시 재발급 + DNS 검증
#      대기(2~5분 × 2장)가 반복되던 마찰 제거
#   3. 참조 방향 건전: CloudFront/ALB(임시) → 인증서(영속) = 임시→영속 OK
#      사용처가 destroy돼도 인증서는 "미사용" 상태로 남을 뿐 무해
#
# 인증서가 2개인 이유:
#   1. CloudFront용: 반드시 us-east-1 발급 (AWS 제약)
#   2. ALB용: ALB 리전(ap-northeast-2) 발급 — HTTPS 리스너 + Okta OIDC
#
# 검증 방식: DNS 검증 (자동 갱신 지원)
#   Hosted Zone은 도메인 등록 시 자동 생성된 영속 자산 → data로 참조만
# ============================================================

# ── 기존 Hosted Zone 조회 ─────────────────────────────────
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ── CloudFront용 인증서 (us-east-1) ───────────────────────
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  # 와일드카드 SAN — www 서브도메인 커버 (단일 인증서로 루트+www)
  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
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

# ── ACM DNS 검증 레코드 ───────────────────────────────────
# 두 인증서의 검증 레코드를 병합 (같은 도메인 → 동일 레코드, 중복 제거)
locals {
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

# ── 검증 완료 대기 ────────────────────────────────────────
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
