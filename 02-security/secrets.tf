# 값 주입 방식 (중요):
#   Terraform은 "빈 시크릿 컨테이너"만 생성
#   실제 값은 CLI로 1회 주입 (아래 주석의 명령 참고)
#   → 시크릿 값이 Terraform state나 tfvars 어디에도 남지 않음
#   → ignore_changes로 Terraform이 값 변경을 추적하지 않음

# Okta OIDC 자격증명 시크릿 컨테이너
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

removed {
  from = aws_secretsmanager_secret_version.okta_oidc

  lifecycle {
    destroy = false
  }
}

# 실제 Okta 값 주입 명령 (apply 후 1회 실행):
#
# aws secretsmanager put-secret-value \
#   --secret-id "dmz/okta/oidc" \
#   --secret-string '{
#     "issuer_url": "https://integrator-xxxxx.okta.com/oauth2/default",
#     "client_id": "0oaXXXXXXXXXXXXX",
#     "client_secret": "실제_시크릿_값"
#   }' \
#   --profile devsecops-admin --region ap-northeast-2
#
# ⚠ project_name이 다르면 secret-id도 그에 맞게 변경
# ⚠ 이 명령은 터미널 히스토리에 남으므로, 실행 후
#    Clear-History 또는 히스토리 파일 정리 권장
