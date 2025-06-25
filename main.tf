



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

# creating a VPC

# AWS doesnt assign a CIDR for this VPC, so for simplicity i will use 10.0.0.0/16

resource "aws_vpc" "main" {
    cidr_block = "118.189.0.0/16"
    enable_dns_support = true # allows DNS resolution inside my VPC
    enable_dns_hostnames = true # allows instances like ec2 inside the vpc to receive DNS hostnames from AWS

}

# subnet a inside the vpc

resource "aws_subnet" "subnet_a" {
  vpc_id = aws_vpc.main.id # puts subnet into vpc
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = "ap-southeast-1a"
}

# subnet b inside the vpc
resource "aws_subnet" "subnet_a" {
  vpc_id = aws_vpc.main.id # puts subnet into vpc
  cidr_block = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone = "ap-southeast-1b"
}

