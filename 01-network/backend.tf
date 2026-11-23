terraform {
  backend "s3" {
    bucket         = "devsecops-project-terraform-state-364652779867"
    key            = "stacks/01-network/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "devsecops-project-terraform-lock"
    encrypt        = true
  }
}
