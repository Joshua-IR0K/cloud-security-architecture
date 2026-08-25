# ============================================================
# 05-k8s/data.tf — 크로스스택 참조
# ============================================================
# 계약 설계(결정 a): 04 는 클러스터 "이름"만 발행하고,
#   endpoint/CA 는 여기서 AWS API 로 조회한다.
#
# ★ 이것이 스택 분리의 핵심 메커니즘:
#   이 값들은 apply 시점에 "이미 존재하는" 실제 값(known)이다.
#   분리 전에는 같은 구성 안의 module.eks 출력이라 unknown 이었고,
#   그래서 프로바이더가 빈 값을 받아 죽었다 (#5/#11).
#   data 소스는 unknown 이 될 수 없으므로 그 실패 모드가 사라진다.
#
# ⚠ 전제: 04-eks 가 먼저 apply 되어 있어야 한다.
#   apply 순서 04 → 05, destroy 순서 05 → 04 (역순).
#   04 가 없으면 이 data 조회가 실패하며, 그것이 올바른 동작이다
#   (잘못된 순서를 조용히 진행하지 않고 명시적으로 막음).
# ============================================================

data "aws_ssm_parameter" "cluster_name" {
  name = "/${var.project_name}/eks/cluster_name"
}

data "aws_eks_cluster" "this" {
  name = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
}

# ── 03-workload (임시) — TGB 가 바인딩할 타깃그룹 ──
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

# ── 01-network (영속) — TGB networking.ingress 소스 SG ──
data "aws_ssm_parameter" "alb_sg_id" {
  name = "/${var.project_name}/network/alb_sg_id"
}

# ── Stage 3: NetworkPolicy ipBlock 정밀 스코프 ──
# ALB ENI 가 사는 퍼블릭 서브넷만 허용 (VPC 전체로 열면 모든 파드가
# nginx 에 접근 가능해져 east-west 세그멘테이션이 무력화됨)
data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/${var.project_name}/network/public_subnet_ids"
}

data "aws_subnet" "public" {
  for_each = toset(split(",", nonsensitive(data.aws_ssm_parameter.public_subnet_ids.value)))
  id       = each.value
}


locals {
  # Stage 4: 04 가 만든 시크릿 이름 — 동일 공식으로 재구성해 SSM 계약을
  # 늘리지 않는다 (결정 a: 계약은 cluster_name 하나)
  s4_secret_name = "${var.project_name}/demo/app-credentials"

  vpc_id              = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  cluster_name        = nonsensitive(data.aws_ssm_parameter.cluster_name.value)
  eks_tg_arn          = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)
  alb_sg_id           = nonsensitive(data.aws_ssm_parameter.alb_sg_id.value)
  public_subnet_cidrs = [for s in data.aws_subnet.public : s.cidr_block]
}
