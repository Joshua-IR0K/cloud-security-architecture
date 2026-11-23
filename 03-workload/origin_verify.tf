# CloudFront에서 ALB로 오는 요청의 출처 확인 헤더. ALB SG의 CloudFront prefix list는 다른 계정 배포도 허용해서 실제 경계는 이 값이다.
# 슬롯이 2개인 이유: ALB 규칙은 몇 초, CloudFront는 엣지 전파에 몇 분이 걸려서 한 번에 바꾸면 그사이 403이 난다. 그래서 병행으로 열고, 전환하고, 닫는다.
#
# 교체 절차(a에서 b로. 03 apply에 늘 붙이던 -var들은 그대로 같이 붙인다):
#   ① 병행 열기 + 새 값 만들기
#        terraform apply -var 'origin_verify_overlap=true' -replace=random_password.origin_verify_b
#   ② CloudFront 전환(배포가 끝날 때까지 apply가 기다린다)
#        terraform apply -var 'origin_verify_overlap=true' -var 'origin_verify_active=b'
#   ③ 병행 닫기 + 옛 값 폐기
#        terraform apply -var 'origin_verify_active=b' -replace=random_password.origin_verify_a
#   그다음부터 이 스택 apply에는 -var 'origin_verify_active=b'를 계속 붙인다
#   (빠뜨리면 ③에서 새로 만든 a로 돌아가는데, ② 없이 바꾸는 거랑 같아서 몇 분 동안 403이 난다).
#   다음 교체는 b에서 a로 같은 절차다. 세션마다 destroy하는 스택이라 새 사이클은 기본값(a)에서 시작한다.
#
# ①에서 b도 새로 만드는 이유: 유출 경로가 state라면 안 쓰던 b 값도 같이 샜다고 봐야 한다.
# ③에서 a를 새로 만드는 이유: 유출된 값이 state에 남아 있다가 실수로 다시 쓰이는 걸 막는다.
# 값은 출력하지 않는다. 확인은 ALB가 받는 값의 "개수"와 사이트 응답 코드로 한다.

variable "origin_verify_active" {
  description = "CloudFront 가 오리진(ALB)에 보내는 X-Origin-Verify 슬롯 (a 또는 b). 교체 절차 ②에서만 바꾼다"
  type        = string
  default     = "a"

  validation {
    condition     = contains(["a", "b"], var.origin_verify_active)
    error_message = "origin_verify_active 는 a 또는 b 여야 한다."
  }
}

variable "origin_verify_overlap" {
  description = "true 면 ALB 가 두 슬롯 값을 모두 받는다 — 교체 절차 ①~② 사이(병행 구간)에만 켠다"
  type        = bool
  default     = false
}

resource "random_password" "origin_verify_a" {
  length  = 32
  special = false
}

resource "random_password" "origin_verify_b" {
  length  = 32
  special = false
}

# 옛 단일 값(random_password.origin_verify)을 슬롯 a가 이어받는다. 살아 있는 스택에서도 값이 안 바뀐다.
moved {
  from = random_password.origin_verify
  to   = random_password.origin_verify_a
}

locals {
  origin_verify_slots = {
    a = random_password.origin_verify_a.result
    b = random_password.origin_verify_b.result
  }

  # CloudFront가 보내는 값. cloudfront.tf의 custom_header
  origin_verify_sent = local.origin_verify_slots[var.origin_verify_active]

  # ALB가 받는 값. alb.tf의 oidc_auth 조건. 평소엔 보내는 값 하나, 병행 구간엔 두 슬롯 다
  origin_verify_accepted = var.origin_verify_overlap ? values(local.origin_verify_slots) : [local.origin_verify_sent]
}
