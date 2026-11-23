# 04는 클러스터 이름만 넘기고, endpoint와 CA는 여기서 조회한다. 04가 없으면 이 조회가 실패하는 게 맞다.

data "aws_ssm_parameter" "cluster_name" {
  name = "/${var.project_name}/eks/cluster_name"
}

data "aws_eks_cluster" "this" {
  name = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
}

# 03-workload(세션 스택). TGB가 붙을 대상 그룹
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

# 01-network(영속 스택). TGB networking.ingress의 출발지 SG
data "aws_ssm_parameter" "alb_sg_id" {
  name = "/${var.project_name}/network/alb_sg_id"
}

# NetworkPolicy 출발지로 쓴다. ALB ENI가 있는 퍼블릭 서브넷만(network-policy.tf).
data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/${var.project_name}/network/public_subnet_ids"
}

# 02에서 만든 ECR 리포지토리 URL(SSM)
data "aws_ssm_parameter" "ecr_repository_url" {
  name = "/${var.project_name}/security/ecr_repository_url"
}

data "aws_subnet" "public" {
  for_each = toset(split(",", nonsensitive(data.aws_ssm_parameter.public_subnet_ids.value)))
  id       = each.value
}

locals {
  # 04가 만든 시크릿 이름. 같은 규칙으로 다시 조립해서 SSM 값을 늘리지 않는다.
  s4_secret_name = "${var.project_name}/demo/app-credentials"

  vpc_id              = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  cluster_name        = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
  eks_tg_arn          = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)
  alb_sg_id           = nonsensitive(data.aws_ssm_parameter.alb_sg_id.value)
  public_subnet_cidrs = [for s in data.aws_subnet.public : s.cidr_block]
  ecr_repository_url  = nonsensitive(data.aws_ssm_parameter.ecr_repository_url.value)
}
