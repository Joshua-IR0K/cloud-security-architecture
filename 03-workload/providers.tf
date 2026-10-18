# ============================================================
# 03-workload/providers.tf
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
      Stack       = "workload"
    }
  }
}

# CloudFront WAF + ACM은 us-east-1
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"

  default_tags {
    tags = {
      Project     = "devsecops-architecture"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "joshua"
      Stack       = "workload"
    }
  }
}
