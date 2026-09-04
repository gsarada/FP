terraform {
  required_version = ">= 1.15"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    
  }
  
  # Using s3 backend - state will be stored in terraform.tfstate in s3 at the path mentioned in terraform init cmd
  backend "s3" {
    bucket         = "fp-app-terraform-state"
    region         = "ap-southeast-1"
    use_lockfile   = true
    encrypt        = true
  }

}

provider "aws" {
  region = var.aws_region
}

# Data source for current caller identity
data "aws_caller_identity" "current" {}
