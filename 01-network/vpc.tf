# ============================================================
# vpc.tf — VPC + Internet Gateway
# ============================================================
# VPC는 모든 AWS 네트워크 리소스의 컨테이너
# IGW는 VPC와 인터넷 사이의 게이트웨이 (Public Subnet용)
# ============================================================

# ── VPC ────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # DNS 설정 — EKS, ALB 등 대부분의 AWS 서비스가 필요로 함
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ── Internet Gateway ───────────────────────────────────────
# IGW가 VPC에 연결되어야 Public Subnet이 인터넷과 통신 가능
# Private Subnet은 IGW로의 라우팅이 없으므로 직접 접근 불가
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}
