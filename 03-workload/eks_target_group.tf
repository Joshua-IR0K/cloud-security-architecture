# 왜 04 가 아니라 03 소유인가:
#   리스너 룰(03)이 이 TG 를 "같은 스택 안에서" weight 0 으로 미리 물고
#   있어야 컷오버 race(빈 TG 로 flip → 502)가 원천 차단됨.
#   04 는 SSM 으로 ARN 만 읽어 TGB 가 파드 IP 를 등록 (03→04 비대칭 계약).
#
# target_type = "ip": 파드 IP 직접 등록 (등록/해제는 04 의
#   TargetGroupBinding + LB Controller 가 자동 수행)
# ALB 헬스체크는 리스너 룰/X-Origin-Verify 게이트를 거치지 않고
#   파드에 직접 도달 → 헤더 없이도 healthy 판정

resource "aws_lb_target_group" "eks" {
  #checkov:skip=CKV_AWS_378:TG HTTP 사용 — TLS 는 CloudFront·ALB 에서 종료, ALB→파드 구간은 VPC 내부 + SG(D19) + NetworkPolicy(app default-deny)로 격리 (alb.tf 의 EC2 TG 와 같은 사유)
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
