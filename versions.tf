terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in the DR region so it is still reachable during a primary region outage.
  # The bucket is created manually (see README); backend blocks cannot use variables.
  backend "s3" {
    bucket       = "coika-dr-tfstate-s3"
    key          = "terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.dr_region

  default_tags {
    tags = {
      Project   = "coika"
      ManagedBy = "terraform"
    }
  }
}
