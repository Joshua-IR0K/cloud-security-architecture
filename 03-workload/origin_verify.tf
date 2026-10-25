# ============================================================
# 03-workload/origin_verify.tf — X-Origin-Verify 2슬롯 (무중단 교체, 멘토 ②)
# ============================================================
#
# 왜 필요한가:
#   이 헤더는 ALB 가 "CloudFront 를 거쳐 온 요청"을 알아보는 표식이다.
#   ALB SG 의 CloudFront prefix list 는 다른 계정의 배포도 허용하므로 실질 경계는 이 값 하나다.
#   값이 state 에 남는데 바꾸는 절차가 없으면, 유출됐을 때 손쓸 방법이 없다.
#
# 왜 슬롯이 2개인가 — 값 하나를 한 번에 바꾸면 끊긴다:
#   ALB 규칙은 몇 초 만에 바뀌지만 CloudFront 설정은 엣지에 퍼지는 데 몇 분이 걸린다
#   (cloudfront.tf 의 wait_for_deployment = true 라 apply 도 그만큼 기다린다).
#   그 몇 분 동안 옛 값을 보내는 엣지의 요청은 ALB 기본 동작(403)에 걸린다.
#   → ALB 가 잠시 두 값을 모두 받게 열고(병행) → CloudFront 를 옮긴 뒤 → 옛 값을 닫는다.
#     (Secrets Manager 회전의 alternating-users 전략과 같은 구조)
#
# 교체 절차 (a → b. 03 apply 에 늘 붙이던 -var 들은 그대로 함께 붙인다):
#   ① 병행 열기 + 새 값 생성
#        terraform apply -var 'origin_verify_overlap=true' -replace=random_password.origin_verify_b
#   ② CloudFront 전환 (배포 완료까지 apply 가 기다린다)
#        terraform apply -var 'origin_verify_overlap=true' -var 'origin_verify_active=b'
#   ③ 병행 닫기 + 옛 값 폐기
#        terraform apply -var 'origin_verify_active=b' -replace=random_password.origin_verify_a
#   이후 이 스택의 apply 에는 -var 'origin_verify_active=b' 를 계속 붙인다
#   (빠뜨리면 ③에서 새로 만든 a 로 되돌아가며 ② 없이 바뀌는 것과 같아 몇 분간 403 이 난다).
#   다음 교체는 b → a 로 같은 절차. 세션마다 destroy 하는 스택이라 새 사이클은 기본값(a)에서 시작한다.
#
# ①에서 b 도 새로 만드는 이유: 유출 경로가 state 라면 쓰지 않던 b 값도 함께 새어 나갔다고 봐야 한다.
# ③에서 a 를 새로 만드는 이유: 유출된 값이 state 에 남아 있다가 실수로 다시 쓰이는 일을 없앤다.
# 값은 출력하지 않는다 — 확인은 ALB 가 받는 값의 "개수"와 사이트 응답 코드로 한다 (런북 6단계).
# ============================================================

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

# 기존 단일 값(cloudfront.tf 에 있던 random_password.origin_verify)을 슬롯 a 가 이어받는다
# — 살아 있는 스택에 적용해도 값이 바뀌지 않는다 (state 가 비어 있으면 아무 일도 하지 않는다)
moved {
  from = random_password.origin_verify
  to   = random_password.origin_verify_a
}

locals {
  origin_verify_slots = {
    a = random_password.origin_verify_a.result
    b = random_password.origin_verify_b.result
  }

  # CloudFront 가 보내는 값 — cloudfront.tf 의 custom_header
  origin_verify_sent = local.origin_verify_slots[var.origin_verify_active]

  # ALB 가 받는 값 — alb.tf 의 oidc_auth 조건. 평소엔 보내는 값 하나, 병행 구간엔 두 슬롯 모두
  origin_verify_accepted = var.origin_verify_overlap ? values(local.origin_verify_slots) : [local.origin_verify_sent]
}
