# terraform setup

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws" # taken from https:#registry.terraform.io/providers/hashicorp/aws/latest
      version = "~> 6.0.0"
    }
  }
}

# to explicitly provide region
provider "aws" {
  region = var.aws_region # to variables.tf file - in case multiple regions
}



# -----------------------------
# 1. VPC
# -----------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16" # Best practice to choose RFC 1918 private ranges https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# -----------------------------
# 1.a Public Subnet (subnet A)
# -----------------------------
# 2. public subnet a - inside the vpc, direct route to IGW
resource "aws_subnet" "subnet_a" {
  vpc_id                  = aws_vpc.main.id # puts subnet into vpc
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "subnet-a-public"
  }
}

# -----------------------------
# 1.b Private Subnet (subnet B)
# -----------------------------
# private subnet b inside the vpc
resource "aws_subnet" "subnet_b" {
  vpc_id                  = aws_vpc.main.id # puts subnet into vpc
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = false # No public IPs in private subnet

  tags = {
    Name = "subnet-b-private"
  }
}

# -----------------------------
# Internet Gateway
# -----------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "terraform-igw"
  }
}

# -----------------------------
# Public Route Table
# -----------------------------
# routes all outbound traffic to IGW
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}



# Associate public subnet A with public routing table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

# -----------------------------
# NAT Gateway for Private Subnet
# -----------------------------
# Allows instances in private subnet B to download updates/packages while staying private - using elastic IP (EIP)
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.subnet_a.id

  tags = {
    Name = "NAT"
  }

  depends_on = [aws_eip.nat_eip] # ensure EIP exists first
}

# -----------------------------
# Private Route Table
# -----------------------------

# Routes outbound traffic via NAT gateway
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "private-routing-table"
  }
}

# Associate private subnet B with private route table
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.subnet_b.id
  route_table_id = aws_route_table.private_rt.id
}


# -----------------------------
# Security Group for NLB
# -----------------------------

# 1. Create Security Group for NLB
resource "aws_security_group" "nlb_sg" {
  name        = "nlb-sg"
  description = "Allow SSH/HTTP to NLB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from TA CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [
      "118.189.0.0/16", # SSH per TA.pdf
      "116.206.0.0/16",
      "223.25.0.0/16"
      , "0.0.0.0/0"
    ]
  }

  ingress {
    description = "HTTP from TA CIDRs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [
      "118.189.0.0/16",
      "116.206.0.0/16",
      "223.25.0.0/16"
      , "0.0.0.0/0"
    ]
  }


  tags = {
    Name = "nlb-sg"
  }
}





# -----------------------------
# Security Group for EC2
# -----------------------------

# Backend EC2 security groups - allow only NLB traffic - I commented away 0.0.0.0/0 for testing using my IP
resource "aws_security_group" "ec2_sg" {
  name   = "ec2-sg"
  vpc_id = aws_vpc.main.id

  # allow health checks and forwarded traffic from NLB nodes
  ingress {
    description     = "SSH from NLB SG"
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    security_groups = [aws_security_group.nlb_sg.id] # allow traffic to EC2 only if it comes from the NLB

  }

  ingress {
    description     = "HTTP from NLB SG"
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.nlb_sg.id] # allow traffic to EC2 only if it comes from the NLB

  }



  # deterministic CIDR rule so health-checks succeed immediately
  ingress {
    description = "Health checks from NLB nodes in subnet A"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 80              # 22–80 inclusive
    cidr_blocks = ["10.0.1.0/24"] # subnet_a CIDR
  }

  # Allow all outbound - no restrictions
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-security-group"
  }
}


# -----------------------------
# Fetch Ubuntu 24.04 LTS AMI
# -----------------------------

# Using SSM parameter store for updated AMIs
data "aws_ssm_parameter" "ubuntu_24_04" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# -----------------------------
# SSH Key Pair
# -----------------------------

# Generates keypair from public-key for ec2 access
resource "aws_key_pair" "deployer" {
  key_name   = "ec2-ssh-key"
  public_key = file("${path.module}/id_rsa.pub")

  tags = {
    Name = "terraform-keypair"
  }
}

# -----------------------------
# EC2 Instance (Nginx + Docker)
# -----------------------------

# Runs in private subnet B, installs docker & nginx container
resource "aws_instance" "nginx" {
  ami                         = data.aws_ssm_parameter.ubuntu_24_04.value
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnet_b.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.deployer.key_name

  tags = {
    Name = "nginx-ec2"
  }

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

# -----------------------------
# Network Load Balancer
# -----------------------------

resource "aws_lb" "web_nlb" {
  name               = "web-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets = [
    aws_subnet.subnet_a.id
  ]
  enable_cross_zone_load_balancing = false
  security_groups = [
    aws_security_group.nlb_sg.id # Attach SG to NLB
  ]
  enforce_security_group_inbound_rules_on_private_link_traffic = "off" # Required flag
}



# -----------------------------
# Target Groups & Listeners
# -----------------------------

# SSH target group
resource "aws_lb_target_group" "tg_ssh" {
  name              = "ssh-target-group"
  port              = 22
  protocol          = "TCP"
  vpc_id            = aws_vpc.main.id
  target_type       = "instance"
  proxy_protocol_v2 = false

  health_check {
    protocol = "TCP"
    port     = "22"
  }
}

# HTTP target group
resource "aws_lb_target_group" "tg_http" {
  name        = "http-target-group"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol = "HTTP"
    path     = "/"
    matcher  = "200-399"
  }
}

# attach EC2 to SSH target group
resource "aws_lb_target_group_attachment" "ssh_attachment" {
  target_id        = aws_instance.nginx.id
  target_group_arn = aws_lb_target_group.tg_ssh.arn
  port             = 22
}

# attach EC2 to HTTP target group
resource "aws_lb_target_group_attachment" "http_attachment" {
  target_id        = aws_instance.nginx.id
  target_group_arn = aws_lb_target_group.tg_http.arn
  port             = 80
}


# SSH Listener
resource "aws_lb_listener" "ssh_listener" {
  load_balancer_arn = aws_lb.web_nlb.arn
  port              = 22
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_ssh.arn
  }
}

# HTTP Listener
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.web_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_http.arn
  }
}
