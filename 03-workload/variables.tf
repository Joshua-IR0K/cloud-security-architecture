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

variable "ec2_instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "애플리케이션 포트"
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "ALB 헬스체크 경로"
  type        = string
  default     = "/"
}

variable "domain_name" {
  description = "Route 53 도메인"
  type        = string
}
