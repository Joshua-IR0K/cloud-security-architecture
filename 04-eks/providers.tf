# ============================================================
# 04-eks/providers.tf — AWS 평면 전용
# ============================================================
# ★ 스택 분리(2026-08) 이후 이 스택에는 kubernetes/helm/kubectl 프로바이더가
#   존재하지 않는다. 그것이 이 리팩토링의 요점:
#
#   [분리 전] 한 스택이 두 평면을 관리 → 프로바이더 설정이 같은 구성 내
#     리소스(module.eks.cluster_endpoint)에 의존 → 클러스터 부재 시 unknown →
#     alekc/kubectl 이 eager 검증에서 즉사 (트러블슈팅 #5)
#     → 우회하려 -target 사용 → 모듈 밖 IAM 정책 부착 누락 (#10)
#     → destroy 부분 실패 후 재시도 시 같은 병 재발 (#11)
#
#   [분리 후] 04 는 AWS API 만 호출 → 순환 자체가 없음 → -target 안무 불필요
# ============================================================

provider "aws" {
  region = var.region

  # 리소스 거버넌스: 소유권 식별 태그 자동 부착
  # (스택 귀속 판별 · 고아 리소스 탐지 · destroy 검증용)
  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "04-eks"
      Phase     = "4B"
      ManagedBy = "terraform"
    }
  }
}
