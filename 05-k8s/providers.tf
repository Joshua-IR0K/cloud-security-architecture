# exec 인증. 프로바이더가 API를 부르는 그 순간에 토큰을 받는다.
# data.aws_eks_cluster_auth로 미리 받아 두면 15분 만료에 걸릴 수 있다.
# aws CLI v2가 PATH에 있어야 하고, 지금 셸의 자격증명(AWS_PROFILE)을 쓴다.

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
  # helm provider v3에서는 kubernetes가 블록이 아니라 속성(=) 문법이다.
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
