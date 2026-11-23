provider "aws" {
  region = var.region

  # 리소스 거버넌스: 소유권 식별 태그 자동 부착
  # (스택 귀속 판별 · 고아 리소스 탐지 · destroy 검증용)
  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "04-eks"
      Phase     = "4B"
      ManagedBy = "terraform"
    }
  }
}
