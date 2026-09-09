# ============================================================
# 02-security/variables.tf
# ============================================================

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI SSO 프로파일"
  type        = string
  default     = "devsecops-admin"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "devsecops-project"
}

variable "alert_email" {
  description = "보안 알림 이메일"
  type        = string
  default     = "zeroone2930@joshua-devsecops.com"
}

# ============================================================
# Stage 6 — CodeBuild-hosted GitHub Actions Runner
# ============================================================
#
# ⚠ `codebuild_runner_enabled` 게이트 제거 (2026-09)
#
#   원래 D37(S6-A/B 분리)에 따라 기본 false 로 두어 S6-A 에서 러너·웹훅
#   실패 도메인을 생성하지 않도록 했다. 게이트의 목적은
#   **CodeConnections 승인 전에 리소스를 만들지 않는 것**이었고,
#   승인이 끝난 시점에 그 목적은 소멸했다.
#
#   목적이 사라진 뒤에도 남겨두면 순수한 위험이 된다 —
#   `-var` 를 빠뜨리면 count=0 이 되어 **에러가 아니라 리소스 삭제**로 나타난다.
#   실제로 러너가 조용히 사라져 AWS 에도 state 에도 없는 상태를 발견했다.
#
#   → 게이트는 목적이 살아있을 때만 유지하고, 소멸하면 제거한다.
#   → 아래 두 변수는 **기본값을 두어 `terraform apply` 만으로 완결**되게 한다.
#     플래그 누락 경로 자체를 없애는 것이 방어보다 낫다.
#
#   ※ 05-k8s 의 network_policy_enforcement 는 유지한다 —
#     BEFORE/AFTER 증적 재현이라는 목적이 살아 있고, 기본값이 fail-secure(true)라
#     빠뜨려도 안전한 쪽으로 실패한다. 게이트 유지 여부의 기준은 "목적의 생존"이다.

variable "github_repo_url" {
  description = "GitHub 저장소 HTTPS URL (CodeBuild source location — 러너 모드에선 형식상 필요)"
  type        = string
  default     = "https://github.com/Joshua-IR0K/cloud-security-architecture"
}

variable "github_connection_arn" {
  description = <<-EOT
    CodeConnections GitHub 연결 ARN (콘솔에서 GitHub App 수동 승인 후 생성).
    ⚠ 시크릿이 아니다 — ARN 만으로는 아무것도 할 수 없고,
      실제 접근은 IAM 정책 + 연결 상태(AVAILABLE)가 결정한다.
    ⚠ 승인 직후에는 연결 상태 전파 지연으로 apply 가 OAuthProviderException 을
      낼 수 있다(#21). IAM 문제가 아니므로 1~2분 후 재시도한다.
  EOT
  type        = string
  default     = "arn:aws:codeconnections:ap-northeast-2:364652779867:connection/0381f302-74a9-4211-9bae-35fce5261c8c"
}

