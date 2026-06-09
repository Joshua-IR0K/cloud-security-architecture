# ============================================================
# 01-network/ssm_outputs.tf — 다른 스택으로 값 전달 (SSM)
# ============================================================
#
# 왜 SSM Parameter Store인가:
#   terraform_remote_state도 가능하지만 SSM이 더 안전함
#   - remote_state: state 파일 전체에 접근 권한 필요 (과도)
#   - SSM: 필요한 값만 선택적으로 공유 (최소 권한)
#   - SSM은 IAM 정책으로 읽기 권한을 세밀하게 제어 가능
#   - 비용: Standard 파라미터 무료
#
# ============================================================

# ── VPC ────────────────────────────────────────────────────
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/${var.project_name}/network/vpc_id"
  type  = "String"
  value = aws_vpc.main.id

  tags = { Name = "${var.project_name}-vpc-id" }
}

# ── Public Subnets ─────────────────────────────────────────
resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "/${var.project_name}/network/public_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.public[*].id)

  tags = { Name = "${var.project_name}-public-subnet-ids" }
}

# ── Private Subnets ────────────────────────────────────────
resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/${var.project_name}/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)

  tags = { Name = "${var.project_name}-private-subnet-ids" }
}

# ── Private Route Table ID (워크로드가 NAT 라우팅 추가 시 필요) ──
resource "aws_ssm_parameter" "private_route_table_id" {
  name  = "/${var.project_name}/network/private_route_table_id"
  type  = "String"
  value = aws_route_table.private.id

  tags = { Name = "${var.project_name}-private-rt-id" }
}

# ── Security Group IDs ─────────────────────────────────────
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

# ── First Public Subnet ID (NAT GW 배치용) ─────────────────
resource "aws_ssm_parameter" "first_public_subnet_id" {
  name  = "/${var.project_name}/network/first_public_subnet_id"
  type  = "String"
  value = aws_subnet.public[0].id

  tags = { Name = "${var.project_name}-first-public-subnet-id" }
}

# ── IGW ID (워크로드에서 참조 필요 시) ─────────────────────
# resource "aws_ssm_parameter" "igw_id" {
#  name  = "/${var.project_name}/network/igw_id"
#  type  = "String"
#  value = aws_internet_gateway.main.id
#
#  tags = { Name = "${var.project_name}-igw-id" }
#} 
