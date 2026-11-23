# aws 프로바이더도 포함 — 단 리소스 생성용이 아니라
# data 조회용(SSM 파라미터 + aws_eks_cluster + get-token 인증).

terraform {
  # Terraform 버전 핀
  #   기술적 최소 요건은 1.11 — write-only 인자(secret_string_wo)가 도입된 버전.
  #   그런데 하한만 두면 로컬이 CI(1.14)보다 앞서가는 걸 막지 못한다.
  #   state 는 상위 버전이 쓰면 하위 버전이 읽지 못하므로(단방향),
  #   로컬만 먼저 올라가면 CI plan 이 전부 깨진다 — 실제로 겪은 위험.
  #   → 상한을 둬서 의도적 업그레이드만 허용한다. 올릴 땐 CI 먼저.
  #   ~> 1.14.0 = >= 1.14.0, < 1.15.0 (패치는 허용, 마이너는 차단)
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.50: 04 와 통일 (Secrets Manager write-only 관련 수정 포함)
      version = ">= 6.50, < 7.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    # S4: CRD 등록 전파 대기
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
