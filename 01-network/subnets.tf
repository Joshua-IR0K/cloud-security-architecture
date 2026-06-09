# ============================================================
# subnets.tf — 3-Tier 서브넷 구조 (Public / Private / Isolated)
# ============================================================
#
# ┌─────────────────────────────────────────────────────────┐
# │ VPC 10.0.0.0/16                                        │
# │                                                         │
# │  Public   │ 10.0.1.0/24 (AZ-a) │ 10.0.2.0/24  (AZ-c) │
# │  역할: ALB, NAT Gateway                                 │
# │  라우팅: 0.0.0.0/0 → IGW                                │
# │                                                         │
# │  Private  │ 10.0.11.0/24(AZ-a) │ 10.0.12.0/24 (AZ-c) │
# │  역할: EC2/EKS 워크로드                                  │
# │  라우팅: 0.0.0.0/0 → NAT GW (아웃바운드만)               │
# │                                                         │
# │  Isolated │ 10.0.21.0/24(AZ-a) │ 10.0.22.0/24 (AZ-c) │
# │  역할: RDS 등 DB (향후)                                  │
# │  라우팅: VPC 내부 통신만 (인터넷 완전 차단)               │
# └─────────────────────────────────────────────────────────┘
#
# ============================================================

# ── Public Subnets ─────────────────────────────────────────
# ALB가 배치되는 서브넷. 인터넷에서 접근 가능해야 하므로
# map_public_ip_on_launch는 false로 유지 (ALB는 자체 IP 사용)
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Public Subnet이라고 해서 자동으로 Public IP를 할당할 필요 없음
  # ALB는 자체적으로 ENI를 생성하고, NAT GW도 EIP를 별도 할당받음
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# ── Private Subnets ────────────────────────────────────────
# EC2/EKS 워크로드가 배치되는 서브넷
# 인터넷에서 직접 접근 불가 — 이게 네트워크 격리의 핵심
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  }
}

# ── Isolated Subnets ──────────────────────────────────────
# DB 전용 서브넷. 인터넷 라우팅이 아예 없음
# VPC 내부 통신(10.0.0.0/16)만 가능
resource "aws_subnet" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-isolated-${var.availability_zones[count.index]}"
    Tier = "isolated"
  }
}
