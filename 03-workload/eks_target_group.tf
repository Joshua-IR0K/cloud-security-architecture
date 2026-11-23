# 03 소유 — 리스너 규칙(03)이 이 대상 그룹을 같은 스택에서 가중치 0 으로 미리 물고 있어야 빈 그룹으로 넘어가는 502 경합이 없다.
# 04 는 SSM 으로 ARN 만 읽고, TargetGroupBinding 과 LB Controller 가 파드 IP 를 등록·해제한다 (target_type = "ip").
# 헬스체크는 리스너 규칙(X-Origin-Verify)을 거치지 않고 파드에 바로 닿는다.

resource "aws_lb_target_group" "eks" {
  #checkov:skip=CKV_AWS_378:TG HTTP 사용 — TLS 는 CloudFront·ALB 에서 종료, ALB→파드 구간은 VPC 내부 + NetworkPolicy(app 기본 차단)로 격리 (alb.tf 의 EC2 TG 와 같은 사유)
  name        = "${var.project_name}-eks-tg" # 타깃그룹 이름 한도 32자 (현재 24자)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  # 컷오버/롤백 속도: 타깃 제거 대기 기본 300초 → 30초
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-eks-tg"
  }
}
