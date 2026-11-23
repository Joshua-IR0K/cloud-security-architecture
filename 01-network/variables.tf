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

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public 서브넷 CIDR"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private 서브넷 CIDR"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "isolated_subnet_cidrs" {
  description = "Isolated 서브넷 CIDR"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "availability_zones" {
  description = "가용 영역"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "app_port" {
  description = "애플리케이션 포트"
  type        = number
  default     = 80
}

variable "eks_pod_port" {
  description = "EKS 파드 컨테이너 포트 (nginx-unprivileged, 3단계 파트 2) — 05-k8s workload.tf 의 container_port 와 같아야 한다"
  type        = number
  default     = 8080
}

variable "domain_name" {
  description = "프로젝트 도메인 (ACM 인증서 + Hosted Zone 조회용)"
  type        = string
}
