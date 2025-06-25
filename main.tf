

# terraform setup
terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws" # taken from https://registry.terraform.io/providers/hashicorp/aws/latest
            version = "~> 6.0"
        }
    }
}

# to explicitly provide region
provider "aws" {
    region = var.aws_region # to variables.tf file
}

# VPC
resource "aws_vpc" "main" {
    cidr_block = "118.189.0.0/16" 
}