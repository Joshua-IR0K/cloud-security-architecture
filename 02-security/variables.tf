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
