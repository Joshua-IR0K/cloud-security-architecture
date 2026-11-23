resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.first_public_subnet

  tags = { Name = "${var.project_name}-nat-gw" }
}

# Private Route Table에 NAT GW 라우팅 추가
# ⚠ aws_route (개별 라우트) — aws_route_table 내 inline route가 아님
#    이렇게 해야 이 스택 destroy 시 라우팅만 삭제되고 RT는 유지됨
resource "aws_route" "private_nat" {
  route_table_id         = local.private_rt_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
