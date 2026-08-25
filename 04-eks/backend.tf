# ============================================================
# 04-eks/backend.tf — Remote State (00-bootstrap 자원 사용)
# ============================================================
#
# ⚠ 치환 필요: bucket / dynamodb_table 을 00-bootstrap 이 만든
#   실제 이름으로, region 을 기존 스택들과 동일하게 맞출 것
#   (01/02/03 의 backend.tf 와 같은 값, key 만 다름)
# ============================================================

terraform {
  backend "s3" {
    bucket         = "devsecops-project-terraform-state-364652779867"   # ⚠ 00-bootstrap 버킷명
    key            = "stacks/04-eks/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "devsecops-project-terraform-lock"    # ⚠ 00-bootstrap 락 테이블명
    encrypt        = true
  }
}
