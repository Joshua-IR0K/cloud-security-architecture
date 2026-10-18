# ============================================================
# 03-workload/eks_target_group.tf — EKS 파드용 IP 타깃그룹 (신규 추가 파일)
# ============================================================
#
# 왜 04 가 아니라 03 소유인가 (설계 검증 확정):
#   리스너 룰(03)이 이 TG 를 "같은 스택 안에서" weight 0 으로 미리 물고
#   있어야 컷오버 race(빈 TG 로 flip → 502)가 원천 차단됨.
#   04 는 SSM 으로 ARN 만 읽어 TGB 가 파드 IP 를 등록 (03→04 비대칭 계약).
#
# target_type = "ip": 파드 IP 직접 등록 (등록/해제는 04 의
#   TargetGroupBinding + LB Controller 가 자동 수행)
# ALB 헬스체크는 리스너 룰/X-Origin-Verify 게이트를 거치지 않고
#   파드에 직접 도달 → 헤더 없이도 healthy 판정 (③ 검증 정상 작동)
#
# 대조 완료(2026-07): local.vpc_id · var.project_name = 03 의 data.tf /
#   variables.tf 실물과 일치 확인. port 80 · path "/" 는 03 의
#   var.app_port(80) / var.health_check_path("/") 현재값과 정렬.
# ============================================================

resource "aws_lb_target_group" "eks" {
  #checkov:skip=CKV_AWS_378:TG HTTP 사용 — TLS 는 CloudFront·ALB 에서 종료, ALB→파드 구간은 VPC 내부 + SG(D19) + NetworkPolicy(app default-deny)로 격리 (alb.tf 의 EC2 TG 와 같은 사유)
  name        = "${var.project_name}-eks-tg" # devsecops-project-eks-tg = 24자 (한도 32)
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
