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

# D37: Part A에서는 runner/webhook 실패 도메인을 완전히 제외한다.
# false = S6-A(Build/Scan/Push/SBOM)만 준비
# true  = S6-B(CodeBuild VPC runner + webhook)까지 생성
variable "codebuild_runner_enabled" {
  description = "Stage 6-B CodeBuild-hosted GitHub Actions runner 생성 여부"
  type        = bool
  default     = false
}

variable "github_repo_url" {
  description = "GitHub 저장소 HTTPS URL (Stage 6-B에서 codebuild_runner_enabled=true일 때 필요)"
  type        = string
  default     = ""
}

variable "github_connection_arn" {
  description = <<-EOT
    CodeConnections 연결 ARN.
    ⚠ 이 연결은 콘솔에서 수동 생성·승인한다. OAuth/GitHub App 승인이
      대화형이므로 Terraform 생성 대상으로 두지 않는다.
      콘솔: Developer Tools → Settings → Connections → Create connection → GitHub
      GitHub App 방식(repo scope)을 사용하고 PAT는 사용하지 않는다.
  EOT
  type        = string
  default     = ""
}

