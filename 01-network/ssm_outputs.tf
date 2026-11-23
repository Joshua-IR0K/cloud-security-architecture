resource "aws_ssm_parameter" "vpc_id" {
  name  = "/${var.project_name}/network/vpc_id"
  type  = "String"
  value = aws_vpc.main.id

  tags = { Name = "${var.project_name}-vpc-id" }
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "/${var.project_name}/network/public_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.public[*].id)

  tags = { Name = "${var.project_name}-public-subnet-ids" }
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/${var.project_name}/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)

  tags = { Name = "${var.project_name}-private-subnet-ids" }
}

# 03 이 NAT 경로를 추가할 라우트 테이블
resource "aws_ssm_parameter" "private_route_table_id" {
  name  = "/${var.project_name}/network/private_route_table_id"
  type  = "String"
  value = aws_route_table.private.id

  tags = { Name = "${var.project_name}-private-rt-id" }
}

resource "aws_ssm_parameter" "alb_sg_id" {
  name  = "/${var.project_name}/network/alb_sg_id"
  type  = "String"
  value = aws_security_group.alb.id

  tags = { Name = "${var.project_name}-alb-sg-id" }
}

resource "aws_ssm_parameter" "app_sg_id" {
  name  = "/${var.project_name}/network/app_sg_id"
  type  = "String"
  value = aws_security_group.app.id

  tags = { Name = "${var.project_name}-app-sg-id" }
}

# 03 이 NAT 게이트웨이를 놓을 서브넷
resource "aws_ssm_parameter" "first_public_subnet_id" {
  name  = "/${var.project_name}/network/first_public_subnet_id"
  type  = "String"
  value = aws_subnet.public[0].id

  tags = { Name = "${var.project_name}-first-public-subnet-id" }
}

# 검증이 끝난 뒤에만 만들어지도록 validation 리소스의 certificate_arn을 사용)
resource "aws_ssm_parameter" "acm_cloudfront_cert_arn" {
  name  = "/${var.project_name}/network/acm_cloudfront_cert_arn"
  type  = "String"
  value = aws_acm_certificate_validation.cloudfront.certificate_arn
}

resource "aws_ssm_parameter" "acm_alb_cert_arn" {
  name  = "/${var.project_name}/network/acm_alb_cert_arn"
  type  = "String"
  value = aws_acm_certificate_validation.alb.certificate_arn
}
