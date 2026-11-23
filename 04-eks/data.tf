# 경로 규칙은 "/${var.project_name}/<stack>/<name>". network·security는 영속 스택이 발행하고,
# workload/eks_target_group_arn은 03이 내려가 있으면 없어서 plan이 실패한다. 04를 CI plan에서 뺀 이유다.

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project_name}/network/private_subnet_ids"
}

# ALB SG는 01(영속 SG)에서 만든다. 03을 거쳐 다시 발행하지 않고 01에서 바로 읽는다.

# APP SG. 노드에 추가로 단다(eks.tf). 01의 ALB egress가 APP SG를 향한다.
data "aws_ssm_parameter" "app_sg_id" {
  name = "/${var.project_name}/network/app_sg_id"
}

data "aws_ssm_parameter" "ebs_kms_key_arn" {
  name = "/${var.project_name}/security/ebs_kms_key_arn"
}

# 데모 시크릿 암호화용 CMK(02-security에서 만든다)
data "aws_ssm_parameter" "secrets_kms_key_arn" {
  name = "/${var.project_name}/security/secrets_kms_key_arn"
}

# 03-workload(세션 스택). 04가 03에 기대는 건 이것 하나다.
data "aws_ssm_parameter" "eks_tg_arn" {
  name = "/${var.project_name}/workload/eks_target_group_arn"
}

locals {
  # nonsensitive(): SSM data 값은 provider가 전부 sensitive로 표시한다. 여기 값은 식별자(ARN·ID)라 풀어 둔다. 안 풀면 출력과 TGB diff가 가려진다.
  # 진짜 비밀(Okta secret 등)에는 절대 쓰지 않는다. 여기는 식별자만.
  vpc_id              = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  private_subnet_ids  = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
  app_sg_id           = nonsensitive(data.aws_ssm_parameter.app_sg_id.value)
  ebs_kms_key_arn     = nonsensitive(data.aws_ssm_parameter.ebs_kms_key_arn.value)
  secrets_kms_key_arn = nonsensitive(data.aws_ssm_parameter.secrets_kms_key_arn.value)
  eks_tg_arn          = nonsensitive(data.aws_ssm_parameter.eks_tg_arn.value)

}
