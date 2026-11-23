resource "aws_lb" "main" {
  #checkov:skip=CKV_AWS_150:삭제 보호 미적용 — workload는 FinOps 원칙상 의도적으로 destroy 가능한 임시 스택
  #checkov:skip=CKV_AWS_91:ALB 액세스 로그 미수집 — 수집처 미정
  #checkov:skip=CKV2_AWS_28:WAF는 CloudFront에 연결(엣지 방어). ALB는 CloudFront 경유만 허용(Prefix List+X-Origin-Verify)하므로 ALB 직접 WAF 불필요
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [local.alb_sg_id]
  subnets            = local.public_subnet_ids

  enable_deletion_protection = false

  # 비정상 HTTP 헤더 차단 — 헤더 스머글링 방어 (CKV_AWS_131 대응)
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:TG HTTP — TLS 는 ALB 에서 종료하고, ALB→대상 구간은 프라이빗 서브넷 + SG 로 격리
  name     = "${var.project_name}-app-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-app-tg"
  }
}

resource "aws_lb_target_group_attachment" "web_test" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.web_test.id
  port             = var.app_port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${var.project_name}-http-redirect"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.alb_cert_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Access Denied - Direct access is not allowed"
      status_code  = "403"
    }
  }

  tags = {
    Name = "${var.project_name}-https-listener"
  }
}

resource "aws_lb_listener_rule" "oidc_auth" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1

  action {
    type = "authenticate-oidc"

    authenticate_oidc {
      authorization_endpoint     = "${local.okta.issuer_url}/v1/authorize"
      client_id                  = local.okta.client_id
      client_secret              = local.okta.client_secret
      issuer                     = local.okta.issuer_url
      token_endpoint             = "${local.okta.issuer_url}/v1/token"
      user_info_endpoint         = "${local.okta.issuer_url}/v1/userinfo"
      on_unauthenticated_request = "authenticate"
      session_timeout            = 3600
      scope                      = "openid profile email"
      session_cookie_name        = "AWSELBAuthSessionCookie"
    }
  }

  # EC2(blue)·EKS(green) 가중치 forward. EKS 대상 그룹을 가중치 0 으로 미리 물려 두면 빈 그룹으로 넘어가는 502 경합이 생기지 않는다.
  # 전환은 가중치 변수로만 한다 (variables_cutover.tf)
  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.app.arn # EC2 (blue)
        weight = var.ec2_traffic_weight
      }

      target_group {
        arn    = aws_lb_target_group.eks.arn # EKS (green)
        weight = var.eks_traffic_weight
      }

      # 컷오버는 명시적 weight 로만 제어 → 세션 고정 불필요.
      # duration 은 enabled=false 여도 필수 이므로 1.
      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }

  # 평소엔 CloudFront 가 보내는 값 하나, 교체 중 병행 구간엔 두 슬롯 모두 받는다 (origin_verify.tf)
  # 여러 값은 OR 로 평가된다 — 하나라도 일치하면 이 규칙(OIDC → forward)으로 간다
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = local.origin_verify_accepted
    }
  }

  tags = {
    Name = "${var.project_name}-oidc-auth-rule"
  }
}
