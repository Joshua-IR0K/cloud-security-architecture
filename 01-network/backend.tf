# ============================================================
# 01-network/backend.tf — Remote State 설정
# ============================================================
# ⚠ bucket과 dynamodb_table 값은 00-bootstrap의 output에서 확인
#    apply 전에 실제 값으로 교체 필요
# ============================================================

terraform {
  backend "s3" {
    bucket         = "devsecops-project-terraform-state-364652779867"
    key            = "stacks/01-network/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "devsecops-project-terraform-lock"
    encrypt        = true
    profile        = "devsecops-admin"
  }
}
