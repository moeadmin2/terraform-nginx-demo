



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

# creating igw for subnet a as stated in the req
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# to create routing table 
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# https://registry.terraform.io/providers/hashicorp/aws/3.6.0/docs/resources/route_table_association for subnet a
resource "aws_route_table_association" "a" { 
  subnet_id = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

# requirement 3 states that allowing access only from specified public CIDR range & protocols, therefore, we need to restrict access by CIDR we need to create security group rules. To allow my ec2 and the gateway created in req. 2 to accept incoming traffic


# to allow ingress from SSH port 22 based on req3, 


# to allow ingress from HTTP port 80 based on req3,


# the is no restriction to block egress (outbound) traffic. adding 0.0.0.0/0 to allow everything



# after creating the vpc, security group, then we create the ec2 instance as needed in req.2



# followed by creating the load balancer - we avoid using the classic load balancer as it is outdated, and deprecated for new builds
# May use an ALB since NLB doesnt support security groups. Since we use HTTP , which is at the application level, using an ALB could be best

