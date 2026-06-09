# ============================================================
# 03-workload/alb.tf — ALB + OIDC 인증 (SSM 참조)
# ============================================================
# 변경: aws_security_group.alb.id → local.alb_sg_id
#       aws_subnet.public[*].id → local.public_subnet_ids
#       aws_vpc.main.id → local.vpc_id
# ============================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [local.alb_sg_id]         # ← SSM 참조
  subnets            = local.public_subnet_ids    # ← SSM 참조

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-app-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = local.vpc_id                        # ← SSM 참조

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

# HTTP → HTTPS 리다이렉트
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

# HTTPS Listener + OIDC
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

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

# Origin Verify + OIDC 인증
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

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }

  tags = {
    Name = "${var.project_name}-oidc-auth-rule"
  }
}
