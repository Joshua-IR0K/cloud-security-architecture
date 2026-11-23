# 경로 규칙 "/${var.project_name}/<stack>/<name>". network·security 는 영속 스택이 발행하고,
# workload/eks_target_group_arn 은 03 이 내려가 있으면 없어서 plan 이 실패한다 — 04 를 CI plan 에서 뺀 이유.

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project_name}/network/private_subnet_ids"
}

# ALB SG 소유자는 01(영속 SG) — 03 경유 재발행 없이 소유자에게서 직접 읽음

# APP SG — 노드에 추가로 단다 (eks.tf). 01 의 ALB egress 가 APP SG 를 향한다
data "aws_ssm_parameter" "app_sg_id" {
  name = "/${var.project_name}/network/app_sg_id"
}

data "aws_ssm_parameter" "ebs_kms_key_arn" {
  name = "/${var.project_name}/security/ebs_kms_key_arn"
}

# 데모 시크릿 암호화용 CMK (02-security 소유)
data "aws_ssm_parameter" "secrets_kms_key_arn" {
  name = "/${var.project_name}/security/secrets_kms_key_arn"
}

# 03-workload (임시) — 04 의 유일한 03 의존
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

locals {
  # nonsensitive(): SSM data 값은 provider 가 일괄 sensitive 로 표시한다. 여기 값은 식별자(ARN·ID)라 풀어 둔다 — 안 풀면 출력과 TGB diff 가 가려진다.
  # ⚠ 진짜 비밀(Okta secret 등)에는 절대 사용 금지 — 여기는 식별자만.
  vpc_id              = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  private_subnet_ids  = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
  app_sg_id           = nonsensitive(data.aws_ssm_parameter.app_sg_id.value)
  ebs_kms_key_arn     = nonsensitive(data.aws_ssm_parameter.ebs_kms_key_arn.value)
  secrets_kms_key_arn = nonsensitive(data.aws_ssm_parameter.secrets_kms_key_arn.value)
  eks_tg_arn          = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)

}
