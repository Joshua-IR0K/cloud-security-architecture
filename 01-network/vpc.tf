resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:Flow Logs는 02-security 스택에 존재 — 정적 스캐너가 스택 간 참조를 인식 못 하는 한계 (실제로는 활성화됨)
  cidr_block = var.vpc_cidr

  # EKS 프라이빗 엔드포인트 이름 풀이에 둘 다 필요하다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# 기본 SG를 관리 대상으로 두고 규칙을 비운다. 실수로 붙여도 통신이 안 되게.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-default-sg-locked"
  }
}