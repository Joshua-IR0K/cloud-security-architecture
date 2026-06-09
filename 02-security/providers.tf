# ============================================================
# 02-security/providers.tf
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "security"
    }
  }
}

# WAF 로그 S3 버킷은 us-east-1에 생성 필요
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "security"
    }
  }
}
