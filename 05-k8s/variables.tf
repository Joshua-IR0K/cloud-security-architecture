# ============================================================
# 05-k8s/variables.tf — K8s 평면 변수
# ============================================================
# ★ 게이트 분리(스택 분리의 부수 효과):
#   cni_node_role_policy_attached → 04-eks (AWS 평면 = IAM)
#   network_policy_enforcement    → 05-k8s (K8s 평면 = 정책 리소스)
#   프로파일도 각 스택의 tfvars/ 에 따로 존재한다.
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

variable "app_image_digest" {
  description = <<-EOT
    ★ D43 갱신 (S7): baseline 을 **digest** 로 참조한다.
      형식: sha256:abc123...  (repo@ 뒤에 붙는 부분)

    왜 태그가 아닌가:
      Kyverno 정책의 verifyDigest=true 가 태그 참조를 거부한다.
      태그 기반 baseline 을 그대로 두면 **재구축 시 05 apply 가 admission 에서
      차단**되어 사이클 자체가 깨진다(체크리스트 #7 ↔ D43 충돌 해소).

    ⚠ 이 digest 의 이미지는 **반드시 서명돼 있어야 한다**(체크리스트 #1).
      미서명 baseline 은 fail-closed 정책에 걸려 Deployment 생성이 거부된다.
      baseline 승격 절차는 STAGE7_RUNBOOK.md 참고.

    조회:
      aws ecr describe-images --repository-name devsecops-project/app \
        --image-ids imageTag=<태그> --query "imageDetails[0].imageDigest" --output text

    의미론은 그대로: 생성 시점에만 반영되고(ignore_changes, D42),
    이후는 CI 가 digest 로 롤포워드한다.
  EOT
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.app_image_digest))
    error_message = "app_image_digest must be a valid sha256:<64 lowercase hex> digest."
  }
}

# ── Stage 7 ────────────────────────────────────────────────
variable "kyverno_chart_version" {
  description = <<-EOT
    Kyverno Helm 차트 버전.

    ★ 차트 버전 ≠ 앱 버전이다 (공식 릴리스 절차 기준):
        chart 3.9.0  ↔  app v1.19.0
      ImageValidatingPolicy(policies.kyverno.io/v1)는 **앱 1.19+** 요건이므로
      차트는 **3.9.x** 여야 한다. 3.6.x 는 1.16 계열이라 해당 CRD 가 없어
      정책 apply 가 실패한다.

    ⚠ ClusterPolicy 는 v1.20(2026-10)에서 제거된다 — 신규 구현은 1.19+ 필수.
    확인: helm search repo kyverno/kyverno --versions | Select-Object -First 5
      (APP VERSION 열이 v1.19.x 인지 함께 볼 것)
  EOT
  type        = string
  default     = "3.9.0"
}

variable "image_verification_action" {
  description = <<-EOT
    Stage 7 source-guard + signature 정책의 동작. **Audit → Deny 순서를 반드시 지킨다.**

    Audit : 위반을 PolicyReport 에 기록하되 배포는 허용.
            이 단계에서 확인 — registry source boundary / 이미지 참조 매칭 / 검증 material /
            Kyverno 의 ECR 접근 / 네임스페이스 스코프 / Pod·Deployment 매칭
    Deny  : 미서명 아티팩트 admission 거부 (S7 머니샷)

    처음부터 Deny 로 시작하면 설정 오류와 정책 동작을 구분할 수 없다.
  EOT
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny"], var.image_verification_action)
    error_message = "Audit 또는 Deny 여야 합니다."
  }
}
