# ============================================================
# security_groups.tf — Security Group Chain (Phase 2 업데이트)
# ============================================================
#
# Phase 1 → Phase 2 변경 사항:
#   ALB SG Inbound: 0.0.0.0/0 → CloudFront Managed Prefix List
#   → 인터넷에서 ALB에 직접 접근하는 것이 네트워크 레벨에서 차단됨
#
# SG Chain:
#   [CloudFront IP만] → ALB-SG (80/443) → APP-SG (80) → DB-SG (3306)
#
# ============================================================

# ── CloudFront Managed Prefix List 조회 ───────────────────
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ── ALB Security Group ─────────────────────────────────────
resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:03-workload 스택의 ALB에 연결됨 — 스택 분리 구조를 정적 스캐너가 인식 못 함
  name        = "${var.project_name}-alb-sg"
  description = "ALB Security Group - CloudFront only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ALB Inbound: HTTP — CloudFront Prefix List만 허용
# ⚠ Phase 1에서는 cidr_blocks = ["0.0.0.0/0"] 이었지만
#    Phase 2에서 prefix_list_ids로 교체됨
resource "aws_security_group_rule" "alb_http_in" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront Managed Prefix List ONLY"
}

# ALB Inbound: HTTPS — CloudFront Prefix List만 허용
resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from CloudFront Managed Prefix List ONLY"
}

# ALB Outbound: APP 포트로만 허용
resource "aws_security_group_rule" "alb_to_app" {
  type                     = "egress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
  description              = "To App instances on app port"
}

# ALB Outbound: EKS 파드 포트 (3단계 파트 2 — nginx-unprivileged 8080)
#   ALB egress 는 APP SG 를 향하도록 설계돼 있다(D19). EKS 노드는 APP SG 를 함께 달고 있어
#   (04 eks.tf vpc_security_group_ids), 파드 IP(노드 ENI 의 보조 IP)로 가는 트래픽도 이 규칙으로 나간다.
#   ⚠ 이 규칙이 없으면 타깃 등록은 되는데 헬스체크가 Target.Timeout — D19 와 같은 함정.
#   80(EC2 경로)과 따로 둔다 — 포트 범위(80-8080)로 묶으면 그 사이 전부가 열린다.
#   인바운드 쪽은 LB Controller 가 TGB networking.ingress 로 노드 SG 에 같은 포트를 연다(05).
resource "aws_security_group_rule" "alb_to_eks_pods" {
  type                     = "egress"
  from_port                = var.eks_pod_port
  to_port                  = var.eks_pod_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
  description              = "To EKS pods (nginx-unprivileged) on pod port"
}

# ALB Outbound: HTTPS → 인터넷 (Okta Token Endpoint 통신에 필요)
# ALB가 OIDC 인증 시 Okta에 직접 HTTPS 요청을 보내야 함
resource "aws_security_group_rule" "alb_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS outbound to Okta Token Endpoint"
}


# ── App (EC2/EKS) Security Group ──────────────────────────
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:03-workload 스택의 EC2에 연결됨 — 스택 분리 구조를 정적 스캐너가 인식 못 함
  name        = "${var.project_name}-app-sg"
  description = "App Security Group - Only ALB can reach"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

resource "aws_security_group_rule" "app_from_alb" {
  type                     = "ingress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
  description              = "From ALB on app port only"
}

resource "aws_security_group_rule" "app_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "HTTPS outbound via NAT GW (ECR, updates)"
}

resource "aws_security_group_rule" "app_http_out" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "HTTP outbound via NAT GW (package managers)"
}

# ── DB Security Group ─────────────────────────────────────
resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:Phase 4B RDS/EKS 데이터 계층 대비 예약 — 의도적 선행 정의
  name        = "${var.project_name}-db-sg"
  description = "DB Security Group - Only App can reach"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-db-sg"
  }
}

resource "aws_security_group_rule" "db_from_app" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.db.id
  description              = "MySQL from App instances only"
}
