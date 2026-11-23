# 03에서 만든다. 리스너 규칙(03)이 같은 스택에서 이 대상 그룹을 가중치 0으로 미리 붙이고 있어야 빈 그룹으로 넘어가는 502 경합이 없다.
# 04는 SSM으로 ARN만 읽고, 파드 IP 등록·해제는 TargetGroupBinding과 LB Controller가 한다(target_type = "ip").
# 헬스체크는 리스너 규칙(X-Origin-Verify)을 안 거치고 파드에 바로 닿는다.

resource "aws_lb_target_group" "eks" {
  #checkov:skip=CKV_AWS_378:TG HTTP 사용 — TLS 는 CloudFront·ALB 에서 종료, ALB→파드 구간은 VPC 내부 + NetworkPolicy(app 기본 차단)로 격리 (alb.tf 의 EC2 TG 와 같은 사유)
  name        = "${var.project_name}-eks-tg" # 대상 그룹 이름은 32자 제한(지금 24자)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  # 전환·롤백 속도: 타깃 제거 대기를 기본 300초에서 30초로 줄인다.
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
