terraform {
  required_version = ">= 1.6.0"

  cloud {
    organization = "CloudGenius"

    workspaces {
      name = "AWS-NETWORK-S2S-ADIRYX-NETWORK"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "Adiryx AWS Site-to-Site VPN"
      Environment = "Lab"
      ManagedBy   = "Terraform Cloud"
      Owner       = "CloudGenius"
      Account     = "adiryx-network"
    }
  }
}

# -----------------------------
# Variables
# -----------------------------

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "expected_aws_account_id" {
  type    = string
  default = "146727531495"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.20.2.0/24"
}

variable "onprem_trust_cidr" {
  type    = string
  default = "10.10.10.0/24"
}

variable "paloalto_customer_gateway_public_ip" {
  type    = string
  default = "172.56.81.232"
}

variable "customer_gateway_bgp_asn" {
  type    = number
  default = 65000
}

# -----------------------------
# Data Sources
# -----------------------------

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

check "correct_aws_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.expected_aws_account_id
    error_message = "Wrong AWS account. This workspace must deploy into adiryx-network account 146727531495."
  }
}

# -----------------------------
# VPC
# -----------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "adiryx-network-vpc"
  }
}

# -----------------------------
# Internet Gateway
# -----------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "adiryx-network-igw"
  }
}

# -----------------------------
# Subnets
# -----------------------------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "adiryx-public-subnet-az1"
    Tier = "Public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "adiryx-private-subnet-az1"
    Tier = "Private"
  }
}

# -----------------------------
# Route Tables
# -----------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "adiryx-public-rt"
  }
}

resource "aws_route" "public_default_to_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "adiryx-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------
# AWS VPN Gateway
# -----------------------------

resource "aws_vpn_gateway" "main" {
  tags = {
    Name = "adiryx-vgw"
  }
}

resource "aws_vpn_gateway_attachment" "main" {
  vpc_id         = aws_vpc.main.id
  vpn_gateway_id = aws_vpn_gateway.main.id
}

# -----------------------------
# Customer Gateway - Palo Alto
# -----------------------------

resource "aws_customer_gateway" "paloalto" {
  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.paloalto_customer_gateway_public_ip
  type       = "ipsec.1"

  tags = {
    Name = "paloalto-pa01-cgw"
  }
}

# -----------------------------
# Site-to-Site VPN
# -----------------------------

resource "aws_vpn_connection" "paloalto" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.paloalto.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = {
    Name = "adiryx-paloalto-s2s-vpn"
  }

  depends_on = [
    aws_vpn_gateway_attachment.main
  ]
}

resource "aws_vpn_connection_route" "onprem_trust" {
  vpn_connection_id      = aws_vpn_connection.paloalto.id
  destination_cidr_block = var.onprem_trust_cidr
}

resource "aws_route" "private_to_onprem_trust" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_trust_cidr
  gateway_id             = aws_vpn_gateway.main.id

  depends_on = [
    aws_vpn_gateway_attachment.main,
    aws_vpn_connection.paloalto
  ]
}

# -----------------------------
# Security Group for Test EC2
# -----------------------------

resource "aws_security_group" "ec2_test" {
  name        = "adiryx-ec2-test-sg"
  description = "Allow validation traffic from Palo Alto Trust Network"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow ICMP from on-prem Trust Network"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.onprem_trust_cidr]
  }

  ingress {
    description = "Allow SSH from on-prem Trust Network"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.onprem_trust_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "adiryx-ec2-test-sg"
  }
}

# -----------------------------
# IAM Role for EC2 SSM
# -----------------------------

resource "aws_iam_role" "ec2_ssm_role" {
  name = "adiryx-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "adiryx-ec2-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "adiryx-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# -----------------------------
# Private EC2 Test Instance
# -----------------------------

resource "aws_instance" "ec2_test_private" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private.id
  private_ip                  = "10.20.2.10"
  vpc_security_group_ids      = [aws_security_group.ec2_test.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm_profile.name
  associate_public_ip_address = false

  tags = {
    Name = "EC2-TEST01-PRIVATE"
  }
}

# -----------------------------
# Outputs
# -----------------------------

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "customer_gateway_id" {
  value = aws_customer_gateway.paloalto.id
}

output "vpn_gateway_id" {
  value = aws_vpn_gateway.main.id
}

output "vpn_connection_id" {
  value = aws_vpn_connection.paloalto.id
}

output "vpn_tunnel_1_outside_ip" {
  value = aws_vpn_connection.paloalto.tunnel1_address
}

output "vpn_tunnel_2_outside_ip" {
  value = aws_vpn_connection.paloalto.tunnel2_address
}

output "vpn_tunnel_1_preshared_key" {
  value     = aws_vpn_connection.paloalto.tunnel1_preshared_key
  sensitive = true
}

output "vpn_tunnel_2_preshared_key" {
  value     = aws_vpn_connection.paloalto.tunnel2_preshared_key
  sensitive = true
}

output "vpn_tunnel_1_cgw_inside_ip" {
  value = aws_vpn_connection.paloalto.tunnel1_cgw_inside_address
}

output "vpn_tunnel_1_vgw_inside_ip" {
  value = aws_vpn_connection.paloalto.tunnel1_vgw_inside_address
}

output "vpn_tunnel_2_cgw_inside_ip" {
  value = aws_vpn_connection.paloalto.tunnel2_cgw_inside_address
}

output "vpn_tunnel_2_vgw_inside_ip" {
  value = aws_vpn_connection.paloalto.tunnel2_vgw_inside_address
}

output "private_ec2_id" {
  value = aws_instance.ec2_test_private.id
}

output "private_ec2_ip" {
  value = aws_instance.ec2_test_private.private_ip
}
