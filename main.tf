terraform {
  backend "s3" {}

  required_providers {
    random = {
      source  = "registry.terraform.io/hashicorp/random"
      version = "~>3.5"
    }
    aws = {
      source  = "registry.terraform.io/hashicorp/aws"
      version = "~>4.0"
    }
  }
}

provider "random" {}
provider "aws" {}


output "DEPLOYED_IMAGE" {
  value = var.dream_env.DOCKER_IMAGES[0]
}
