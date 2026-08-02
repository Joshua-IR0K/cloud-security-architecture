# ============================================================
# 04-eks/versions.tf — Terraform / Provider 버전 핀
# ============================================================
#
# 핀 근거 (2026-06 검증):
#   - aws ~> 6.0        : EKS 모듈 v21 이 provider v6 요구
#   - kubernetes ~> 2.35: nginx Deployment/Service (typed 리소스)
#   - helm ~> 3.0       : LB Controller 설치
#       ⚠ v3 는 v2 와 문법이 다름 — kubernetes "블록"이 아니라
#         kubernetes "속성"(= { ... }) 문법 (providers.tf 참고)
#   - kubectl (alekc)   : TargetGroupBinding(CRD) 전용
#       HashiCorp kubernetes_manifest 는 plan 시점에 CRD 존재를
#       요구해 fresh apply 가 불가 → apply 시점 적용인 kubectl 사용
#       (gavinbunney 원본은 미유지보수 → alekc 유지보수 포크)
# ============================================================

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
