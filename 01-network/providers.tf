# ============================================================
# 01-network/providers.tf
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

provider "aws" {
  region  = var.aws_region

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "network"
    }
  }
}

# Cloudfront용 인증서 us_east_1 발급 필수(AWS 제약)
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "network"
    }
  }
}