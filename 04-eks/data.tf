# ============================================================
# 04-eks/data.tf — 크로스스택 SSM 참조 (계약 5개, 실발행명 대조 완료)
# ============================================================
#
# 네이밍 관용구: 01/02/03 과 동일 — "/${var.project_name}/<stack>/<name>"
# 인라인 보간 + 언더스코어 (2026-07 실발행 목록 대조: ADAPTER_RECONCILIATION.md)
#
# 발행자와 CI 특성:
#   network/*  ← 01 (영속) ┐
#   security/* ← 02 (영속) ┴ 03 이 destroy 상태여도 조회 가능
#   workload/eks_target_group_arn ← 03 (임시) — 03 이 내려가 있으면
#     ParameterNotFound 로 plan 실패. 04 를 상시 CI plan 에서 제외한
#     유일한 원인이 이 한 줄 (README §5)
# ============================================================

data "aws_caller_identity" "current" {}

# ── 01-network (영속) ─────────────────────────────────────
data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project_name}/network/private_subnet_ids"
}

# ALB SG 소유자는 01(영속 SG) — 03 경유 재발행 없이 소유자에게서 직접 읽음
data "aws_ssm_parameter" "alb_sg_id" {
  name = "/${var.project_name}/network/alb_sg_id"
}

# APP SG — 노드 ENI 에 추가 부착 (D19, Target.Timeout 트러블슈팅 결과)
#   ALB SG 의 egress 가 APP SG 를 향하도록 01 에서 설계돼 있었음(EC2 전제).
#   EKS 노드는 모듈이 만든 별도 SG 를 쓰므로 ALB→파드 경로가 끊김 →
#   노드에 APP SG 를 함께 붙여 기존 검증된 경계 체인을 그대로 재사용.
data "aws_ssm_parameter" "app_sg_id" {
  name = "/${var.project_name}/network/app_sg_id"
}

# Stage 3: NetworkPolicy ipBlock 정밀 스코프 — ALB ENI 가 사는 퍼블릭 서브넷만
# 허용하기 위해 CIDR 이 필요 (VPC 전체로 열면 east-west 세그멘테이션 무력화)
data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/${var.project_name}/network/public_subnet_ids"
}

data "aws_subnet" "public" {
  for_each = toset(split(",", nonsensitive(data.aws_ssm_parameter.public_subnet_ids.value)))
  id       = each.value
}

# ── 02-security (영속) ────────────────────────────────────
data "aws_ssm_parameter" "ebs_kms_key_arn" {
  name = "/${var.project_name}/security/ebs_kms_key_arn"
}

# ── 03-workload (임시) — 04 의 유일한 03 의존 ─────────────
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

locals {
  # nonsensitive(): SSM data source 의 value 는 provider 가 일괄 sensitive 마킹함.
  # 이 값들(ARN/ID)은 비밀이 아니고, sensitive 상태로 두면
  #   - outputs.tf 의 verify 명령 output 이 "Output refers to sensitive values" 로 plan 실패
  #   - TGB yaml_body 전체가 sensitive 로 물들어 diff 가 가려짐
  # ⚠ 진짜 비밀(Okta secret 등)에는 절대 사용 금지 — 여기는 식별자만.
  vpc_id             = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  private_subnet_ids = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
  alb_sg_id          = nonsensitive(data.aws_ssm_parameter.alb_sg_id.value)
  app_sg_id          = nonsensitive(data.aws_ssm_parameter.app_sg_id.value)
  ebs_kms_key_arn    = nonsensitive(data.aws_ssm_parameter.ebs_kms_key_arn.value)
  eks_tg_arn         = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)

  # Stage 3: ALB 진입 허용용 CIDR 목록
  public_subnet_cidrs = [for s in data.aws_subnet.public : s.cidr_block]
}
