# ============================================================
# 05-k8s/backend.tf — 원격 state (00-bootstrap 의 S3 + DynamoDB)
# ============================================================
# ⚠ REPLACE-ME 2곳을 00-bootstrap 실제 값으로 치환
# ============================================================

terraform {
  backend "s3" {
    bucket         = "devsecops-project-terraform-state-364652779867" # ⚠ 00-bootstrap 버킷명
    key            = "stacks/05-k8s/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "devsecops-project-terraform-lock" # ⚠ 00-bootstrap 락 테이블명
    encrypt        = true
  }
}
