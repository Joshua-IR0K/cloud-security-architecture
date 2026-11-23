data "aws_caller_identity" "current" {}

# 01-network 스택에서 생성한 값 읽기
data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/network/vpc_id"
}

locals {
  vpc_id = data.aws_ssm_parameter.vpc_id.value
}
