# ============================================================
# 03-workload/data.tf — 다른 스택에서 값 읽기 (SSM)
# ============================================================

data "aws_caller_identity" "current" {}

# ── 01-network 스택에서 읽기 ──────────────────────────────
data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.project_name}/network/vpc_id"
}

data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/${var.project_name}/network/public_subnet_ids"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${var.project_name}/network/private_subnet_ids"
}

data "aws_ssm_parameter" "private_route_table_id" {
  name = "/${var.project_name}/network/private_route_table_id"
}

data "aws_ssm_parameter" "alb_sg_id" {
  name = "/${var.project_name}/network/alb_sg_id"
}

data "aws_ssm_parameter" "app_sg_id" {
  name = "/${var.project_name}/network/app_sg_id"
}

data "aws_ssm_parameter" "first_public_subnet_id" {
  name = "/${var.project_name}/network/first_public_subnet_id"
}

#data "aws_ssm_parameter" "igw_id" {
#  name = "/${var.project_name}/network/igw_id"
#}

# ── 02-security 스택에서 읽기 ─────────────────────────────
data "aws_ssm_parameter" "waf_log_bucket_arn" {
  name = "/${var.project_name}/security/waf_log_bucket_arn"
}

data "aws_ssm_parameter" "ebs_kms_key_arn" {
  name = "/${var.project_name}/security/ebs_kms_key_arn"
}

data "aws_ssm_parameter" "okta_secret_arn" {
  name = "/${var.project_name}/security/okta_secret_arn"
}

data "aws_ssm_parameter" "acm_cloudfront_cert_arn" {
  name = "/${var.project_name}/network/acm_cloudfront_cert_arn"
}
data "aws_ssm_parameter" "acm_alb_cert_arn" {
  name = "/${var.project_name}/network/acm_alb_cert_arn"
}


# ── Secrets Manager에서 Okta 자격증명 읽기 ────────────────
# tfvars 대신 Secrets Manager에서 런타임에 읽음
data "aws_secretsmanager_secret_version" "okta" {
  secret_id = data.aws_ssm_parameter.okta_secret_arn.value
}

# ── 로컬 변수로 변환 (코드 가독성) ────────────────────────
locals {
  vpc_id               = data.aws_ssm_parameter.vpc_id.value
  public_subnet_ids    = split(",", data.aws_ssm_parameter.public_subnet_ids.value)
  private_subnet_ids   = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  private_rt_id        = data.aws_ssm_parameter.private_route_table_id.value
  alb_sg_id            = data.aws_ssm_parameter.alb_sg_id.value
  app_sg_id            = data.aws_ssm_parameter.app_sg_id.value
  first_public_subnet  = data.aws_ssm_parameter.first_public_subnet_id.value
  #igw_id               = data.aws_ssm_parameter.igw_id.value
  waf_log_bucket_arn   = data.aws_ssm_parameter.waf_log_bucket_arn.value
  ebs_kms_key_arn     = data.aws_ssm_parameter.ebs_kms_key_arn.value
  cloudfront_cert_arn = data.aws_ssm_parameter.acm_cloudfront_cert_arn.value
  alb_cert_arn        = data.aws_ssm_parameter.acm_alb_cert_arn.value

  # Secrets Manager의 JSON을 파싱해서 Okta 값 추출
  okta = jsondecode(data.aws_secretsmanager_secret_version.okta.secret_string)
  # 사용: local.okta.issuer_url, local.okta.client_id, local.okta.client_secret
}
