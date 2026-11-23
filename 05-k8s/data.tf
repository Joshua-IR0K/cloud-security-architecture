# 계약 설계: 04 는 클러스터 "이름"만 발행하고,
#   endpoint/CA 는 여기서 AWS API 로 조회한다.
#
# ⚠ 전제: 04-eks 가 먼저 apply 되어 있어야 한다.
#   04 가 없으면 이 data 조회가 실패하며, 그것이 올바른 동작이다
#   (잘못된 순서를 조용히 진행하지 않고 명시적으로 막음).

data "aws_ssm_parameter" "cluster_name" {
  name = "/${var.project_name}/eks/cluster_name"
}

data "aws_eks_cluster" "this" {
  name = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
}

# 03-workload (임시) — TGB 가 바인딩할 타깃그룹
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

# 01-network (영속) — TGB networking.ingress 소스 SG
data "aws_ssm_parameter" "alb_sg_id" {
  name = "/${var.project_name}/network/alb_sg_id"
}

# S3: NetworkPolicy ipBlock 정밀 스코프
# ALB ENI 가 사는 퍼블릭 서브넷만 허용 (VPC 전체로 열면 모든 파드가
# nginx 에 접근 가능해져 east-west 세그멘테이션이 무력화됨)
data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/${var.project_name}/network/public_subnet_ids"
}

# S5: 02-security (영속) — 자체 ECR repository URL
# URL 만 SSM 으로 계약하고 02 state 전체를 참조하지 않는다.
data "aws_ssm_parameter" "ecr_repository_url" {
  name = "/${var.project_name}/security/ecr_repository_url"
}

data "aws_subnet" "public" {
  for_each = toset(split(",", nonsensitive(data.aws_ssm_parameter.public_subnet_ids.value)))
  id       = each.value
}

locals {
  # S4: 04 가 만든 시크릿 이름 — 같은 공식으로 재구성해 SSM 계약을 늘리지 않는다
  s4_secret_name = "${var.project_name}/demo/app-credentials"

  vpc_id              = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  cluster_name        = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
  eks_tg_arn          = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)
  alb_sg_id           = nonsensitive(data.aws_ssm_parameter.alb_sg_id.value)
  public_subnet_cidrs = [for s in data.aws_subnet.public : s.cidr_block]
  ecr_repository_url  = nonsensitive(data.aws_ssm_parameter.ecr_repository_url.value)
}
