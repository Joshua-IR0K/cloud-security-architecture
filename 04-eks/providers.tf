provider "aws" {
  region = var.region

  # 리소스 거버넌스: 소유 식별 태그를 자동으로 붙인다
  # (어느 스택 건지 판별, 고아 리소스 탐지, destroy 검증용)
  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "04-eks"
      Phase     = "4B"
      ManagedBy = "terraform"
    }
  }
}
