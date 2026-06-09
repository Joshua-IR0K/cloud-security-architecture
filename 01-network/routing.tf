# ============================================================
# 01-network/routing.tf — 라우트 테이블 (NAT GW 라우팅 제외)
# ============================================================
#
# ⚠ Phase 4A와의 차이점:
#   Private RT에서 NAT GW 라우팅이 제거됨
#   NAT GW는 고비용($42/월)이라 03-workload 스택에 배치
#   워크로드 스택이 apply되면 NAT GW + 해당 라우팅이 추가됨
#   워크로드 스택이 destroy되면 NAT 라우팅도 함께 삭제됨
#   → Private Subnet은 아웃바운드 불가 상태가 되지만,
#     인바운드 차단(보안)은 유지됨
#
# ============================================================

# ── Public Route Table ─────────────────────────────────────
# 0.0.0.0/0 → Internet Gateway
# ALB와 NAT GW가 인터넷과 통신할 수 있게 함
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  # VPC 내부 통신(10.0.0.0/16 → Local)은 자동으로 포함됨

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Public Subnet ↔ Public Route Table 연결
resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Table (NAT GW 라우팅 없음) ──────────────
# NAT GW 라우팅은 03-workload 스택에서 aws_route로 추가됨
# 워크로드 destroy 시 이 라우팅만 삭제되고 RT 자체는 유지
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # ⚠ route 블록 없음 — NAT GW는 03-workload에서 관리
  # 워크로드 미실행 시: Private Subnet은 아웃바운드 불가
  # 워크로드 실행 시: aws_route로 0.0.0.0/0 → NAT GW 추가

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Private Subnet ↔ Private Route Table 연결
resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidrs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Isolated Route Table ──────────────────────────────────
# 인터넷 라우팅 없음 — VPC 내부 통신(Local)만 가능
# DB는 외부와 통신할 이유가 없으므로 완전 격리
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id

  # route 블록 없음 → 0.0.0.0/0 라우팅이 존재하지 않음
  # 기본 Local 라우팅(10.0.0.0/16)만 동작

  tags = {
    Name = "${var.project_name}-isolated-rt"
  }
}

# Isolated Subnet ↔ Isolated Route Table 연결
resource "aws_route_table_association" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}
