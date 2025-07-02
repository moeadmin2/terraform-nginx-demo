# terraform setup
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws" # taken from https:#registry.terraform.io/providers/hashicorp/aws/latest
      version = "~> 6.0"
    }
  }
}

# to explicitly provide region
provider "aws" {
  region = var.aws_region # to variables.tf file
}

# creating a VPC
resource "aws_vpc" "main" {
  cidr_block = "118.189.0.0/16" # allows DNS resolution inside my VPC

  enable_dns_support   = true
  enable_dns_hostnames = true
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

# https:#registry.terraform.io/providers/hashicorp/aws/3.6.0/docs/resources/route_table_association for subnet a
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
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    # given in the requirements
    cidr_blocks = ["118.189.0.0/16"]
  }

  # to allow ingress from HTTP port 80 based on req3,
  # http
  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    # given in the requirements
    cidr_blocks = ["118.189.0.0/16", "116.206.0.0/16", "223.25.0.0/16"]
  }

  egress = {
    from_port = 0
    to_port = 0
    protocol = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#didnt put egress since there are no outbound restrictions

# after creating the vpc, security group, then we create the ec2 instance as needed in req.2
# add ec2

data "aws_ami" "ubuntu_24_04" {  # if the question specifically want 24.04 LTS OS
  most_recent = true             # as tested in aws, get the latest compatible ami
  owners      = ["099720109477"] # referenced from here: https:#documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/ canonical should be official publisher

  filter {
    name   = "name"
    values = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-*-amd64-server-*"
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
  user_data = <<-EOF
#!/bin/bash
set -e

apt update -y # update package index
apt install -y docker.io # install docker

# Enable and start Docker
systemctl enable docker 
systemctl start docker

# Start Nginx container
docker run -d --name nginx -p 80:80 nginx

# Sleep awhile
sleep 5

# Replace default Nginx homepage with custom content
echo "<h1>Glenn Yeo</h1>" > /tmp/index.html
docker cp /tmp/index.html nginx:/usr/share/nginx/html/index.html
EOF
}

# followed by creating the load balancer - we avoid using the classic load balancer as it is outdated, and deprecated for new builds
# after consultation, we will use an NLB instead, 
resource "aws_lb" "web_nlb" {
  name                       = "web-nlb"
  internal                   = false
  load_balancer_type         = "network"
  subnets                    = [aws_subnet.subnet_a.id]
  enable_deletion_protection = false
}

# adding target group for SSH
resource "aws_lb_target_group" "tg_ssh" {
  name        = "ssh-target-group"
  port        = 22
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
}

# adding target group for HTTP
resource "aws_lb_target_group" "tg_http" {
  name        = "http-target-group"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
}

resource "aws_lb_target_group_attachment" "ssh_attachment" {
  target_id        = aws_instance.nginx.id
  target_group_arn = aws_lb_target_group.tg_ssh.arn
  port             = 22
}

resource "aws_lb_target_group_attachment" "http_attachment" {
  target_id        = aws_instance.nginx.id
  target_group_arn = aws_lb_target_group.tg_http.arn
  port             = 80
}

resource "aws_lb_listener" "ssh_listener" {
  load_balancer_arn = aws_lb.web_nlb.arn
  port              = 22
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_ssh.arn
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.web_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_http.arn
  }
}
