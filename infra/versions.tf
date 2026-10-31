terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # Each workspace (dev/prod) gets its own state file automatically.
  backend "s3" {
    bucket       = "agent-ops-tfstate-147848993439"
    key          = "agent-ops/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "agent-ops"
      Environment = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}