# ============================================================
# 05-k8s/providers.tf — K8s 평면 전용
# ============================================================
# 분리 전과 결정적으로 다른 점:
#   host/CA 가 data.aws_eks_cluster (= 이미 존재하는 실제 값)에서 오므로
#   unknown 이 될 수 없다 → alekc/kubectl 의 eager 검증이 항상 통과.
#   → -target 안무 불필요, destroy 도 정상 동작.
#
# exec 인증: 프로바이더가 API 를 칠 "그 순간" 토큰을 발급받는다.
#   data.aws_eks_cluster_auth 로 미리 뜨면 15분 만료에 걸릴 수 있음.
#   ⚠ aws CLI v2 가 PATH 에 있어야 하고, ambient 자격증명(AWS_PROFILE)을 사용.
# ============================================================

provider "aws" {
  region = var.region
}

locals {
  cluster_endpoint = data.aws_eks_cluster.this.endpoint
  cluster_ca       = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec_args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

provider "helm" {
  # helm provider v3: kubernetes 가 블록이 아니라 "속성(=)" 문법
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}
