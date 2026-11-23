# Okta OIDC 시크릿은 그릇만 만든다.
# 값은 Terraform 밖에서 넣는다.

resource "aws_secretsmanager_secret" "okta_oidc" {
  #checkov:skip=CKV2_AWS_57:자동 로테이션 미적용 — Okta는 서드파티 시크릿으로 AWS 네이티브 로테이션 불가(커스텀 Lambda 필요, 현 단계 과잉). 수동 로테이션 정책으로 운영
  name        = "${var.project_name}/okta/oidc"
  description = "Okta OIDC credentials for ALB authentication"

  kms_key_id = aws_kms_key.secrets.id

  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}-okta-oidc"
  }
}
# 값 버전은 Terraform 관리에서 뺀다(삭제는 안 한다). 값이 state에 남지 않게.
removed {
  from = aws_secretsmanager_secret_version.okta_oidc

  lifecycle {
    destroy = false
  }
}
