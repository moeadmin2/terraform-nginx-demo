



# terraform setup
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws" # taken from https://registry.terraform.io/providers/hashicorp/aws/latest
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
  cidr_block           = "118.189.0.0/16"
  enable_dns_support   = true # allows DNS resolution inside my VPC
  enable_dns_hostnames = true # allows instances like ec2 inside the vpc to receive DNS hostnames from AWS

}

# subnet a inside the vpc

resource "aws_subnet" "subnet_a" {
  vpc_id                  = aws_vpc.main.id # puts subnet into vpc
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-1a"
}

# subnet b inside the vpc
resource "aws_subnet" "subnet_b" {
  vpc_id                  = aws_vpc.main.id # puts subnet into vpc
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-1b"
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
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

# requirement 3 states that allowing access only from specified public CIDR range & protocols, therefore, we need to restrict access by CIDR we need to create security group rules. To allow my ec2 and the gateway created in req. 2 to accept incoming traffic
# to create security group
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id

  # to allow ingress from SSH port 22 based on req3, 

  # ssh
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["118.189.0.0/16"] // given in the requirements
  }

  # to allow ingress from HTTP port 80 based on req3,
  # http
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["118.189.0.0/16", "116.206.0.0/16", "223.25.0.0/16"] // given in the requirements
  }
}

#didnt put egress since there are no outbound restrictions

# after creating the vpc, security group, then we create the ec2 instance as needed in req.2
# add ec2

data "aws_ami" "ubuntu_24_04" {  # if the question specifically want 24.04 LTS OS
  most_recent = true             # as tested in aws, get the latest compatible ami
  owners      = ["099720109477"] # referenced from here: https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/ canonical should be official publisher


  filter {
    name   = "name"
    values = "ubuntu/images/hvm-ssd/ubuntu-xenial-20.08-amd64-server-*" # sources - https://discourse.ubuntu.com/t/search-and-launch-ubuntu-22-04-in-aws-using-cli/27986 https://stackoverflow.com/questions/63899082/terraform-list-of-ami-specific-to-ubuntu-20-08-lts-aws
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

}

resource "aws_instance" "nginx" {
  ami                         = data.aws_ami.ubuntu_24_04.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnet_b.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = false

  # to add custom shell script since i need to deploy this nginx service with the docker container and customise the nginx config to display my name on default page
  user_data = "#!/bin/bash\n apt update -y \n apt install -y docker.io \n systemctl start docker \n docker run -d --name nginx -p 80:80 nginx \n echo \"<h1>Glenn Yeo</h1>\" > index.html \n docker exec -i nginx /bin/bash -c 'cat > /usr/share/nginx/html/index.html' < index.html"

}


# followed by creating the load balancer - we avoid using the classic load balancer as it is outdated, and deprecated for new builds
# May use an ALB since NLB doesnt support security groups. Since we use HTTP , which is at the application level, using an ALB could be best

# resource 1: the alb itself - this alb must be public so that it can route traffic from the internet to my ec2 -  means that this alb must be in a public subnet
# 
resource "aws_alb" "web_alb" {
  name               = "web-alb"
  load_balancer_type = "application"
  subnets            = [aws_subnet.subnet_a.id]
  security_groups    = [aws_security_group.web_sg.id] # link to the SG we made earlier
}


# resource 2: where this alb routes traffic to - i will tell them which vpc, what protocol to use, what port etc.
resource "aws_alb_target_group" "tg" {
  protocol = "http"
  name     = "nginx-tg"
  port     = 80
  vpc_id   = aws_vpc.main.id
}

# resource 3: attaching the aws instance nginx to the target group
resource "aws_alb_target_group_attachment" "tga" {
  port             = 80
  target_group_arn = aws_alb_target_group.tg.arn
  target_id        = aws_instance.nginx.id

}

# resource 4: accepts these traffic and defines the rules on what to do next
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.web_alb.arn
  protocol          = "http"
  port              = 80
  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.tg.arn
  }
}
