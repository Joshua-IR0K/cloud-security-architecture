# ============================================================
# 02-security/secrets.tf — Secrets Manager (Okta 자격증명)
# ============================================================
#
# 목적: Okta Client Secret 등 민감 정보를 terraform.tfvars에서
#       제거하고 Secrets Manager로 중앙 관리
#
# 보안 개선 효과:
#   변경 전: 03-workload/terraform.tfvars에 Okta Secret 평문 저장
#            → 로컬 파일 유출 시 노출 위험
#   변경 후: Secrets Manager에 KMS 암호화 저장
#            → 워크로드는 IAM 권한으로 런타임에만 읽음
#            → tfvars에서 시크릿 완전 제거
#
# 값 주입 방식 (중요):
#   Terraform은 "빈 시크릿 컨테이너"만 생성
#   실제 값은 CLI로 1회 주입 (아래 주석의 명령 참고)
#   → 시크릿 값이 Terraform state나 tfvars 어디에도 남지 않음
#   → ignore_changes로 Terraform이 값 변경을 추적하지 않음
#
# ============================================================

# ── Okta OIDC 자격증명 시크릿 컨테이너 ────────────────────
resource "aws_secretsmanager_secret" "okta_oidc" {
  #checkov:skip=CKV2_AWS_57:자동 로테이션 미적용 — Okta는 서드파티 시크릿으로 AWS 네이티브 로테이션 불가(커스텀 Lambda 필요, 현 단계 과잉). 수동 로테이션 정책으로 운영
  name        = "${var.project_name}/okta/oidc"
  description = "Okta OIDC credentials for ALB authentication"

  # 시크릿 암호화에 전용 KMS 키 사용
  kms_key_id = aws_kms_key.secrets.id

  # 삭제 시 복구 대기 기간 (실수 방지)
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}-okta-oidc"
  }
}

# ── 초기 플레이스홀더 값 ──────────────────────────────────
# Terraform은 빈 골격만 생성. 실제 값은 CLI로 주입.
# ignore_changes로 이후 값 변경을 Terraform이 추적하지 않음
resource "aws_secretsmanager_secret_version" "okta_oidc" {
  secret_id = aws_secretsmanager_secret.okta_oidc.id

  secret_string = jsonencode({
    issuer_url    = "PLACEHOLDER_REPLACE_VIA_CLI"
    client_id     = "PLACEHOLDER_REPLACE_VIA_CLI"
    client_secret = "PLACEHOLDER_REPLACE_VIA_CLI"
  })

  lifecycle {
    # 실제 값은 CLI로 주입되므로, Terraform은 값 변경을 무시
    # 이게 없으면 apply마다 플레이스홀더로 덮어씀
    ignore_changes = [secret_string]
  }
}

# ──────────────────────────────────────────────────────────
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
# ──────────────────────────────────────────────────────────
