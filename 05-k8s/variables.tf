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
  EOT
  type        = bool
  default     = false
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
