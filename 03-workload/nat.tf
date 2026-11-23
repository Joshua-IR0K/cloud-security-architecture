resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.first_public_subnet

  tags = { Name = "${var.project_name}-nat-gw" }
}

# 01 의 프라이빗 라우트 테이블에 개별 aws_route 로 기본 경로를 넣는다 — inline route 가 아니라서 03 을 지워도 라우트 테이블은 남음
resource "aws_route" "private_nat" {
  route_table_id         = local.private_rt_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
