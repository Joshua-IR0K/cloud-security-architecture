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

# CodeBuild 러너 입력. 기본값이 있어서 -var 없이 apply만 하면 된다.

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
