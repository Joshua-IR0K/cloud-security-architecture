resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:Flow Logs는 02-security 스택에 존재 — 정적 스캐너가 스택 간 참조를 인식 못 하는 한계 (실제로는 활성화됨)
  cidr_block = var.vpc_cidr

  # DNS 설정 — EKS, ALB 등 대부분의 AWS 서비스가 필요로 함
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

# VPC default SG 잠금 — 규칙을 모두 제거해 실수 사용 차단
# (Terraform이 이 리소스를 "관리"하며 빈 규칙 상태를 강제)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  # ingress/egress 블록 없음 = 모든 트래픽 차단

  tags = {
    Name = "${var.project_name}-default-sg-locked"
  }
}
