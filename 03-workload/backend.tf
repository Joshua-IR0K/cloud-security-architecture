# ============================================================
# 03-workload/backend.tf
# ============================================================

terraform {
  backend "s3" {
    bucket         = "devsecops-project-terraform-state-364652779867"
    key            = "stacks/03-workload/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "devsecops-project-terraform-lock"
    encrypt        = true
  }
}
