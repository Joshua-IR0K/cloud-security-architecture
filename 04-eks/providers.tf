# ============================================================
# 04-eks/providers.tf — Provider 구성 (B-1 부트스트랩 설계 반영)
# ============================================================
#
# 핵심: 모든 k8s 계열 프로바이더는 exec 인증 사용
#   - data.aws_eks_cluster_auth 방식(static token)은 plan 시점에
#     토큰을 떠서 15분 만료 → 클러스터 생성(15~20분)이 낀 첫 apply 에서
#     워크로드 적용 시점에 토큰 사망(Unauthorized)
#   - exec 는 API 호출 "그 순간" aws eks get-token 즉석 발급 → 만료 race 소멸
#   - 요구사항: terraform 실행 머신에 aws CLI v2 필수
#   - get-token 은 ambient 자격증명 사용 → Stage 1 은 클러스터 생성자(나)
#     = enable_cluster_creator_admin_permissions 의 admin access entry 로 인증
# ============================================================

provider "aws" {
  region = var.region

  # 리소스 거버넌스: 04-eks 의 모든 리소스에 소유권 식별 태그 자동 부착
  # (스택 귀속 판별 · 고아 리소스 탐지 · destroy 검증용.
  #  태깅 기반 FinOps 아키텍처는 스코프 제외 결정(2026-07) — Cost Allocation
  #  Tag 활성화 없이도 태그 자체는 거버넌스 가치가 있고, FinOps 재도입 시
  #  콘솔 활성화만 켜면 됨 — 태그는 이미 전 리소스에 부착돼 있으므로)
  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "04-eks"
      Phase     = "4B"
      ManagedBy = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}

# helm provider v3: kubernetes 는 "블록"이 아니라 "속성" 문법 (= 필요)
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.region,
      ]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}
