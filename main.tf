terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

# Configuring the AWS Provider
## note: In order to keep the keys secret, I have elected not to push my tfvars file
variable "aws_access_key" {}
variable "aws_secret_key" {}
provider "aws" {
  region = "us-east-1"
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
}

# Creating a VPC with the provided CIDR
resource "aws_vpc" "main-vpc" {
  cidr_block = "10.1.0.0/16"
}
# Creating a gateway for the subnets exposed to the internet
resource "aws_internet_gateway" "main-gw" {
  vpc_id = aws_vpc.main-vpc.id
}
# Creating multiple subnets
## note: I could variabilize and make a loop to minimize repititive code here but for the purpose of this challenge, I elected to keep it simple for timesake
resource "aws_subnet" "sub1" {
  vpc_id     = aws_vpc.main-vpc.id
  cidr_block = "10.1.0.0/24"
  availability_zone = "us-east-1a"
  tags = {
      Name = "sub1"
  }
}
resource "aws_subnet" "sub2" {
  vpc_id     = aws_vpc.main-vpc.id
  cidr_block = "10.1.1.0/24"
  availability_zone = "us-east-1b"
  tags = {
      Name = "sub2"
  }
}
resource "aws_subnet" "sub3" {
  vpc_id     = aws_vpc.main-vpc.id
  cidr_block = "10.1.2.0/24"
  availability_zone = "us-east-1a"
  tags = {
      Name = "sub3"
  }
}
resource "aws_subnet" "sub4" {
  vpc_id     = aws_vpc.main-vpc.id
  cidr_block = "10.1.3.0/24"
  availability_zone = "us-east-1b"
  tags = {
      Name = "sub4"
  }
}
# Creating a route table
resource "aws_route_table" "main-route-table" {
  vpc_id = aws_vpc.main-vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main-gw.id
  }
}

# Associate public subnets with route table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.sub1.id
  route_table_id = aws_route_table.main-route-table.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.sub2.id
  route_table_id = aws_route_table.main-route-table.id
}
#Creating security groups to allow port 22,80,443
resource "aws_security_group" "allow_all" {
  name        = "allow_all_traffic"
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.main-vpc.id
  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] 
  }
  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] 
  }
  ingress {
    description      = "SSH"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] 
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}
#Creating security groups to allow port 22 only (following least privilege rule)
resource "aws_security_group" "allow_ssh_only" {
  name        = "allow_ssh_only"
  description = "Allow SSH"
  vpc_id      = aws_vpc.main-vpc.id
  ingress {
    description      = "SSH"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] 
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}

#Creating EC2 according to provided specifications
resource "aws_instance" "sub2_instance" {
    ami = "ami-0b0af3577fe5e3532"
    instance_type = "t2.micro"
    key_name = "main-key"
    subnet_id = aws_subnet.sub2.id
    availability_zone = aws_subnet.sub2.availability_zone
    security_groups = [aws_security_group.allow_ssh_only.id]
    ebs_block_device {
        device_name = "/dev/sda1"
        volume_size = 20
    }
}
#Assign elastic IP to sub2 instance to give it an IP for SSH
resource "aws_eip" "sub2_instance_eip" {
  vpc      = true
  instance = aws_instance.sub2_instance.id
  depends_on = [aws_internet_gateway.main-gw]
}

#Creating ALB
## to create it we need one target group and one listener
resource "aws_lb" "alb" {
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_all.id]
  subnets            = [aws_subnet.sub3.id, aws_subnet.sub4.id]
}
resource "aws_lb_listener" "listener_http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.group.arn
    type             = "forward"
  }
}
resource "aws_lb_target_group" "group" {
  port        = 80
  protocol    = "HTTP"
  vpc_id     = aws_vpc.main-vpc.id
}

#Create an ASG
## to create it, we need one template file and one launch template
### template file holds commands to script installation of Apache
data "template_file" "install_apache" {
  template = <<EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install apache2 -y
    sudo systemctl start apache2
    sudo bash -c 'echo your very first web server > /var/www/html/index.html'
    EOF
}
### launch template could be replaced by launch config but this method is newer and recommended by AWS
resource "aws_launch_template" "template" {
  image_id = "ami-0b0af3577fe5e3532"
  instance_type = "t2.micro"
  user_data = "${base64encode(data.template_file.install_apache.rendered)}"
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
    }
  }
}
### here we create the ASG 
resource "aws_autoscaling_group" "autoscale-group" {
  max_size = 6
  min_size = 2
  vpc_zone_identifier= [aws_subnet.sub3.id, aws_subnet.sub4.id]
  launch_template {
    id      = aws_launch_template.template.id
    version = "$Latest"
  }
}
# Creating S3 Bucket with two folders and lifecycle policies
resource "aws_s3_bucket" "main-bucket" {
  bucket = "main-bucket0001"
}
resource "aws_s3_bucket_object" "main-bucket-images" {
  bucket = aws_s3_bucket.main-bucket.id
  key = "Images/"
}
resource "aws_s3_bucket_object" "main-bucket-logs" {
  bucket = aws_s3_bucket.main-bucket.id
  key = "Logs/"
}
resource "aws_s3_bucket_lifecycle_configuration" "lifecycle-policies" {
  bucket = aws_s3_bucket.main-bucket.id

  rule {
    status = "Enabled"
    id = "glacier"
    filter {
        prefix = "Images/"
    }
    transition {
      days = 90
      storage_class = "GLACIER"
    }
  }
  rule {
    status = "Enabled"
    id = "expired"
    filter {
        prefix = "Logs/"
    }
    expiration {
      days = 90
    }
  }
}
output "server_public_ip" {
  value = aws_eip.sub2_instance_eip.public_ip
}
