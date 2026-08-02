# ============================================================
# 04-eks/variables.tf
# ============================================================
# SSM 파라미터 경로는 별도 변수 없이 data.tf 에서
# "/${var.project_name}/<stack>/<name>" 인라인 보간 — 01/02/03 관용구와 통일.
# (실발행명 대조 완료 2026-07 — ADAPTER_RECONCILIATION.md)
# ============================================================

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름 (01/02/03 과 동일 — SSM 경로 프리픽스로도 사용)"
  type        = string
  default     = "devsecops-project"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "joshua-eks"
}

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전 (결정 #4: 1.35)"
  type        = string
  default     = "1.35"
}

# ── API 엔드포인트 (결정 #7: 혼합 모드) ───────────────────
variable "my_ip" {
  description = <<-EOT
    kubectl 을 실행할 내 공인 IP (예: "1.2.3.4" — /32 는 자동 부착).
    Stage 1 혼합 모드: public 엔드포인트를 이 IP 로만 제한. 후반 Private 전환 예정.

    주입 채널 — tfvars 금지, 세션 환경변수 (scripts/session-ritual.ps1):
      $env:TF_VAR_my_ip = (현재 공인 IPv4 자동 조회)
    → 디스크·VCS 에 값이 남지 않고(OPSEC), 매 세션 Terraform "입력"은 현재
      IP 로 자동 갱신됨. ⚠ 단 기존 클러스터의 allowlist(실제 상태)는 과거
      IP 를 유지하므로, IP 로테이션 후에는 관리 평면 잠금 해제가 선행 필수:
      terraform apply -target=module.eks   (module.eks = 전부 AWS 평면 리소스
      → K8s 프로바이더가 그래프에서 제외돼 잠긴 endpoint 를 안 두드림.
      리추얼 스크립트가 드리프트를 감지해 이 명령을 안내함 — README §2)

    sensitive = true 인 이유: 자격증명은 아니지만(접근 인증은 IAM/access
    entries 가 담당 — /32 는 표면 축소 계층) 거주지 공인 IP 는 OPSEC 민감
    식별자. 공개 리포·증거 트랜스크립트에 남지 않게 plan 출력에서 마스킹.
    정직한 한계: state 와 DescribeCluster 응답에는 존재 — 통제 대상은
    "공개 산출물"이지 AWS 계정 내부가 아님.
  EOT
  type      = string
  sensitive = true

  # 가드레일: 외부 API 응답이 보안 통제(allowlist)로 유입되는 지점의 입력 검증.
  # 엔드포인트 장애/변조로 쓰레기 값(HTML 에러 페이지, 빈 문자열, 다중 행)이
  # 주입되면 apply 의 모호한 AWS 에러 대신 plan 에서 명확히 조기 차단.
  # 정직한 한계: "형식이 올바른 남의 IP"(MITM)는 못 잡음 — 그건 HTTPS +
  # AWS 운영 엔드포인트(checkip.amazonaws.com) 신뢰로 커버하는 계층.
  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$", var.my_ip))
    error_message = "my_ip 가 단일 IPv4 형식이 아님 — TF_VAR_my_ip 주입 누락 또는 IP echo 엔드포인트 장애/변조 의심. allowlist 오염 방지를 위해 중단."
  }
}

# ── 노드그룹 (결정 #6: 스테이지별 다이얼 1→2) ─────────────
variable "node_desired_size" {
  description = "노드 수 — 생성 시점 초기값으로만 반영됨 (운영 중 스케일은 CLI, 런북 §4)"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = <<-EOT
    최소 노드 수. 기본 0 인 이유(설계 결정):
    모듈이 생성 후 desired_size 변경을 ignore_changes 처리하므로
    Pause/Resume 은 CLI(aws eks update-nodegroup-config)로 수행함.
    min=0 이면 CLI 로 desired 를 0↔1↔2 로 움직여도 Terraform plan 과
    충돌("min > desired" 에러·drift)이 원천적으로 없음.
  EOT
  type        = number
  default     = 0
}

variable "node_max_size" {
  description = "최대 노드 수"
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "노드 인스턴스 타입 (CNI/시스템 파드 메모리 고려 t3.medium 최소)"
  type        = string
  default     = "t3.medium"
}

# ── LB Controller ─────────────────────────────────────────
variable "lb_controller_chart_version" {
  description = <<-EOT
    aws-load-balancer-controller Helm 차트 버전.
    기본값 1.14.0 = AWS 공식 EKS 문서(2026-05) 안내 버전 (LBC v2.14 대응).
    최신 3.x 는 차트-컨트롤러 버전 정렬 + Gateway API CRD 전제조건이
    추가되므로 Stage 1 은 문서 검증 버전으로 고정, 업그레이드는 후속 증분.
    확인: helm search repo eks/aws-load-balancer-controller --versions
  EOT
  type        = string
  default     = "1.14.0"
}

