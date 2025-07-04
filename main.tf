# terraform setup

# Note - due to troubleshooting difficulties with NLBs, I used bastion host to enter the nginx host. I limited it to my own IP address

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
  cidr_block              = "118.189.1.0/24"
  availability_zone       = "ap-southeast-1a"

  tags = {
    name = "subnet-a-public"
  }
}

# subnet b inside the vpc
resource "aws_subnet" "subnet_b" {
  vpc_id                  = aws_vpc.main.id # puts subnet into vpc
  cidr_block              = "118.189.2.0/24"
  availability_zone       = "ap-southeast-1b"

  tags = {
    name = "subnet-b-private"
  }
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



# i am adding this NAT gateway in subnet A so the ec2 can access the internet via outbound for docker install and other scripts like update
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id = aws_subnet.subnet_a.id
}

# I am trying to give private subnet B outbound internet access so the curl/apt install can work, but i dont want to assign a public IP to these instance to comply with the requirement(s)

# I create a custom routing table for private subnet B, any traffic from that EC2 to the internet goes through this NAT gateway in order to run scripts
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

# binding subnet B to that custom routing table I made earlier, if not subnet B may use the default routing table that may not have NAT and block access
resource "aws_route_table_association" "private" {
  subnet_id = aws_subnet.subnet_b.id
  route_table_id = aws_route_table.private_rt.id
}




# https:#registry.terraform.io/providers/hashicorp/aws/3.6.0/docs/resources/route_table_association for subnet a
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

# commenting this out, to associate subnet B to another custom routing table
# resource "aws_route_table_association" "b" {
#   subnet_id      = aws_subnet.subnet_b.id
#   route_table_id = aws_route_table.public_rt.id
# }

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
    # cidr_blocks = ["118.189.0.0/16"]
    cidr_blocks = ["118.189.0.0/16" ]
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#didnt put egress since there are no outbound restrictions

# after creating the vpc, security group, then we create the ec2 instance as needed in req.2
# add ec2

data "aws_ssm_parameter" "ubuntu_24_04" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# data "aws_ami" "ubuntu_24_04" {  # if the question specifically want 24.04 LTS OS
#   most_recent = true             # as tested in aws, get the latest compatible ami
#   owners      = ["099720109477"] # referenced from here: https:#documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/ canonical should be official publisher

#   filter {
#     name   = "image-id"
#     values = [data.aws_ssm_parameter.ubuntu_24_04.value]
#   }

#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }
# }

resource "aws_key_pair" "deployer" {
  key_name   = "ec2-ssh-key"
  public_key = file("${path.module}/id_rsa.pub")
}


resource "aws_instance" "nginx" {
  ami                         = data.aws_ssm_parameter.ubuntu_24_04.value
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnet_b.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.deployer.key_name
  # according to the PDF, it states that ".. An EC2 instance with a key pair assigned running on subnet B with Ubuntu 24.04 LTS OS." I cant find any assigned keypair, so I will be 

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



resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.ubuntu_24_04.value
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnet_a.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  key_name                    = aws_key_pair.deployer.key_name

  tags = {
    Name = "bastion-host"
  }

  user_data = <<-EOF
#!/bin/bash
apt update -y
apt install -y curl net-tools
EOF
}


resource "aws_security_group" "bastion_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["158.140.141.64/32"] # my own IP address - testing purposes
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
}

resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["118.189.0.0/16", "116.206.0.0/16", "223.25.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_lb_target_group" "http_tg" {
  name        = "http-target"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check {
    path     = "/"
    protocol = "HTTP"
  }
}

resource "aws_lb_target_group_attachment" "http_attachment" {
  target_group_arn = aws_lb_target_group.http_tg.arn
  target_id        = aws_instance.nginx.id
  port             = 80
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http_tg.arn
  }
}

# I am unable to make the NLB work - reverting back to bastion host for easier entry to SSH

# resource "aws_lb" "web_nlb" {
#   name                       = "web-nlb"
#   internal                   = false
#   load_balancer_type         = "network"
#   subnets                    = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
#   enable_deletion_protection = false
# }

# # adding target group for SSH
# resource "aws_lb_target_group" "tg_ssh" {
#   name        = "ssh-target-group"
#   port        = 22
#   protocol    = "TCP"
#   vpc_id      = aws_vpc.main.id
#   target_type = "instance"
#   proxy_protocol_v2 = false
# }

# # adding target group for HTTP
# resource "aws_lb_target_group" "tg_http" {
#   name        = "http-target-group"
#   port        = 80
#   protocol    = "TCP"
#   vpc_id      = aws_vpc.main.id
#   target_type = "instance"
# }

# resource "aws_lb_target_group_attachment" "ssh_attachment" {
#   target_id        = aws_instance.nginx.id
#   target_group_arn = aws_lb_target_group.tg_ssh.arn
#   port             = 22
# }

# resource "aws_lb_target_group_attachment" "http_attachment" {
#   target_id        = aws_instance.nginx.id
#   target_group_arn = aws_lb_target_group.tg_http.arn
#   port             = 80
# }

# resource "aws_lb_listener" "ssh_listener" {
#   load_balancer_arn = aws_lb.web_nlb.arn
#   port              = 22
#   protocol          = "TCP"

#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.tg_ssh.arn
#   }
# }

# resource "aws_lb_listener" "http_listener" {
#   load_balancer_arn = aws_lb.web_nlb.arn
#   port              = 80
#   protocol          = "TCP"

#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.tg_http.arn
#   }
# }
