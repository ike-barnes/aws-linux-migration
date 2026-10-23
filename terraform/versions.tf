terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: terraform init -backend-config=env/prod.s3.tfbackend
  backend "s3" {
    use_lockfile = true # S3-native state locking (Terraform >= 1.10); no DynamoDB table
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "linux-aws-migration"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
