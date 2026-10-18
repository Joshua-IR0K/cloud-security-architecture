# ============================================================
# 05-k8s/variables.tf — K8s 평면 변수
# ============================================================
# ★ 게이트 분리(스택 분리의 부수 효과):
#   cni_node_role_policy_attached → 04-eks (AWS 평면 = IAM)
#   network_policy_enforcement    → 05-k8s (K8s 평면 = 정책 리소스)
#   현재 final bundle은 실제 적용값을 terraform.tfvars 또는 명시적 -var 로 전달한다.
# ============================================================

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름 (SSM 경로 프리픽스 — 04/03/01 과 동일해야 함)"
  type        = string
  default     = "devsecops-project"
}

variable "lb_controller_chart_version" {
  description = <<-EOT
    aws-load-balancer-controller Helm 차트 버전.
    1.14.0 = AWS 공식 EKS 문서 검증 버전. 3.x 는 Gateway API CRD 전제조건이
    추가되므로 후속 판단 (D18 — Gateway API 채택 계획은 없음).
  EOT
  type        = string
  default     = "1.14.0"
}

variable "network_policy_enforcement" {
  description = <<-EOT
    NetworkPolicy 리소스 생성(=집행) 여부. 기본 false.
    애드온의 enableNetworkPolicy(04-eks)는 항상 켜두고 이 게이트로 정책만
    토글한다 — before/after 차이가 "정책만" 반영되게 하기 위함.
    ⚠ true 로 켜기 전 EKS 트래픽 가중치 확인: 정책 오류로 헬스체크가 깨지면
      eks=100 상태에선 사이트가 503. 실습은 ec2=100 으로 롤백 후 권장.

    ★ 기본값 true (fail-secure, S6 교정):
      과거에는 BEFORE 실증 편의를 위해 false 가 기본이었으나,
      "아무 tfvars 없이 apply 해도 보안 기준선을 훼손하지 않아야 한다"는 원칙에 따라
      기본값을 안전한 쪽으로 뒤집었다.
      → 정상 운영 = fail-secure / 과거 증적 재현 = 명시적 opt-out(s3-before.tfvars)
      실수로 var-file 을 빠뜨렸을 때 정책이 사라지는 대신 유지된다.
  EOT
  type        = bool
  default     = true
}

variable "secrets_csi_chart_version" {
  description = <<-EOT
    secrets-store-csi-driver-provider-aws (ASCP) Helm 차트 버전.
    ⚠ Pod Identity 지원은 0.3.11 부터 — 그 이전 버전은 IRSA 만 가능(D8 충돌).
    ⚠ 차트 v2 는 CSI 드라이버를 의존성으로 함께 설치한다.
    확인: helm search repo secrets-store-csi-driver-provider-aws --versions
  EOT
  type        = string
  default     = "1.0.1"
}

variable "secrets_store_driver_version" {
  description = <<-EOT
    secrets-store-csi-driver (드라이버 본체) Helm 차트 버전.
    ★ SecretProviderClass CRD 를 제공하는 것이 이 차트다 — ASCP 가 아니다(#14).
    확인:
      helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
      helm search repo secrets-store-csi-driver/secrets-store-csi-driver --versions
  EOT
  type        = string
  default     = "1.5.4"
}

variable "app_image_tag" {
  description = <<-EOT
    ★ 의미 재정의 (D43): 이 값은 "현재 실행 중인 이미지"가 아니라
      **bootstrap / creation-time baseline** 이다.

    Deployment 의 image 필드는 lifecycle.ignore_changes 로 CI 에 위임돼 있다(D42).
    따라서 이 변수는 **Deployment 가 처음 생성될 때만** 반영되고,
    그 이후 변경(-var / tfvars)은 plan 에 나타나지 않는다.
      → EKS 모듈의 desired_size 와 동일한 "생성 시점 전용" 의미론(D6).

    사이클 동작 (destroy/apply 반복 환경에서 중요):
      apply        → 이 baseline 이미지로 기동
      CI 배포      → s6-<sha>@<digest> 로 롤포워드 (Terraform 은 이를 되돌리지 않음)
      destroy/apply → 다시 baseline 으로 시작
      = 재구축은 "알려진 기준선"에서 출발하고 CI 가 앞으로 굴린다 (채택 원칙 가)
      = 최신 이미지를 재구축 직후 원하면 CI 를 재실행한다 (검증 세션 한정 절차 나)

    [3단계 파트 2] baseline 을 tag + digest 로 고정한다 (아래 app_image_digest).
      baseline = 파트 1 머지 커밋(acde70e)에서 CI 가 빌드·스캔·푸시한 비루트 이미지 (UID 101 · 8080).
      ⚠ 이전 baseline(baseline-v1 = root 로 실행되는 이미지)으로 되돌리면 app 네임스페이스의
        PSA restricted 와 securityContext(runAsNonRoot)에 거부되어 파드가 뜨지 않는다.
      digest 가 실제 고정점이므로 baseline-vN 재태깅은 더 하지 않는다 — CI 가 붙인
      s6-<커밋> 태그를 그대로 쓰면 어느 커밋의 산출물인지 이름만으로 추적된다.

    baseline 갱신 시점: 검증된 이미지를 새 기준선으로 승격할 때만 tag·digest 를 함께 올린다.
    ⚠ 리포지토리가 IMMUTABLE 이라 같은 태그 재푸시는 불가.
      digest 고정은 여기(3단계)서 하고, 서명 검증(cosign)은 S7 에서 더한다.

    ⚠ 현재 ECR lifecycle 은 **untagged image만 1일 후 자동 정리**한다.
      s5-*/s6-*/baseline-* 등 tagged artifact는 자동 만료하지 않는다 (baseline 이 사라지지 않는 근거).
      개인 포트폴리오 규모에서는 복잡한 tagged retention보다 재현성·증거 보존을
      우선하고, 필요 시 스테이지 종료 후 수동 정리한다.
  EOT
  type        = string
  default     = "s6-acde70ed6ca5bef7c879ceeb57162a6162bcaade"
}

variable "app_image_digest" {
  description = "기준 이미지의 digest — app_image_tag 와 짝. 태그는 이름, digest 가 실제 내용이다 (ECR IMMUTABLE 위에 한 겹 더)"
  type        = string
  default     = "sha256:7eff1cbda7393d518350701ad971d8f561c5a236790854ee0d7c5de9c5ee82ea"

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.app_image_digest))
    error_message = "app_image_digest 는 sha256:<64자리 hex> 형식이어야 한다."
  }
}
