# 왜 Alias 레코드는 workload에 남는가:
#   레코드의 대상(CloudFront)이 임시 리소스 → "레코드는 자기가
#   가리키는 리소스와 같은 스택에" 원칙. 영속으로 빼면
#   영속→임시 참조가 생기고, CloudFront 재생성마다(도메인 변경)
#   영속 스택 재apply가 강제됨.

# 기존 Hosted Zone 조회
# (01-network에도 동일 data가 있으나, data는 조회일 뿐이라 중복 무해)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

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
