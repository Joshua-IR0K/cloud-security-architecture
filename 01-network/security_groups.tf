data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:03-workload 스택의 ALB에 연결됨 — 스택 분리 구조를 정적 스캐너가 인식 못 함
  name        = "${var.project_name}-alb-sg"
  description = "ALB Security Group - CloudFront only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group_rule" "alb_http_in" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront Managed Prefix List ONLY"
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from CloudFront Managed Prefix List ONLY"
}

resource "aws_security_group_rule" "alb_to_app" {
  type                     = "egress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
  description              = "To App instances on app port"
}

# ALB → EKS 파드(8080). 노드가 APP SG 를 함께 달고 있어(04 eks.tf) 파드 IP 로 가는 트래픽도 이 규칙을 탄다.
# 없으면 타깃 등록은 되지만 헬스체크가 Target.Timeout. 80 과 범위로 묶지 않는다 — 사이 포트가 전부 열린다.
# 노드 SG 쪽 인바운드는 LB Controller 가 TargetGroupBinding 으로 연다 (05 workload.tf).
resource "aws_security_group_rule" "alb_to_eks_pods" {
  type                     = "egress"
  from_port                = var.eks_pod_port
  to_port                  = var.eks_pod_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
  description              = "To EKS pods (nginx-unprivileged) on pod port"
}

# ALB 가 OIDC 인증 중 Okta 토큰 엔드포인트를 직접 호출 (443)
resource "aws_security_group_rule" "alb_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS outbound to Okta Token Endpoint"
}

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

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:데이터 계층용으로 미리 만든 SG — 현재 연결된 리소스 없음
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
