terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --------------------
# DATA SOURCES (no hard-coded AMI IDs / AZ names)
# --------------------
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  public_az  = data.aws_availability_zones.available.names[0]
  private_az = length(data.aws_availability_zones.available.names) > 1 ? data.aws_availability_zones.available.names[1] : data.aws_availability_zones.available.names[0]
  tags = {
    Project   = var.project_name
    AccountId = data.aws_caller_identity.current.account_id
    Region    = data.aws_region.current.id
  }
}

# --------------------
# VPC + Subnets
# --------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.public_az
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${var.project_name}-public" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = local.private_az

  tags = merge(local.tags, { Name = "${var.project_name}-private" })
}

# --------------------
# Route tables
# --------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.project_name}-rt-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT for private subnet outbound access (updates, docker pulls, etc.)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.project_name}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]

  tags = merge(local.tags, { Name = "${var.project_name}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.project_name}-rt-private" })
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --------------------
# Key Pair
# --------------------
resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.public_key_path)
  tags       = merge(local.tags, { Name = "${var.project_name}-key" })
}

# ============================================================
# SECURITY GROUPS — Desired Layout
# ============================================================

# 1) Vote/Result SG: inbound HTTP/HTTPS from internet
resource "aws_security_group" "sg_vote_result" {
  name        = "${var.project_name}-sg-vote-result"
  description = "Vote/Result: allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Bastion SSH from your IP
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    description = "Outbound anywhere"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-sg-vote-result" })
}

# 2) Redis/Worker SG: inbound 6379 only from Vote/Result SG; outbound to Postgres
resource "aws_security_group" "sg_redis_worker" {
  name        = "${var.project_name}-sg-redis-worker"
  description = "Redis/Worker: allow Redis from Vote/Result; outbound to Postgres"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Redis 6379 from Vote/Result SG"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_result.id]
  }

  ingress {
    description     = "SSH from Vote/Result SG (bastion)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_result.id]
  }

  egress {
    description = "Outbound anywhere (includes Postgres 5432)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-sg-redis-worker" })
}

# 3) Postgres SG: inbound 5432 only from Worker SG (and optionally Vote/Result)
resource "aws_security_group" "sg_postgres" {
  name        = "${var.project_name}-sg-postgres"
  description = "Postgres: allow 5432 from Redis/Worker only (optional Vote/Result)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres 5432 from Redis/Worker SG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_redis_worker.id]
  }

  # Optional: allow Result (on Vote/Result host) to connect to Postgres directly
  dynamic "ingress" {
    for_each = var.allow_vote_result_to_postgres ? [1] : []
    content {
      description     = "Postgres 5432 from Vote/Result SG (optional)"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.sg_vote_result.id]
    }
  }

  ingress {
    description     = "SSH from Vote/Result SG (bastion)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_result.id]
  }

  egress {
    description = "Outbound anywhere"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-sg-postgres" })
}

# --------------------
# EC2 Instances
# --------------------
# A: Public subnet (Bastion + Vote + Result)
resource "aws_instance" "a_vote_result" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.sg_vote_result.id]

  tags = merge(local.tags, { Name = "A-bastion-vote-result" })
}

# B: Private subnet (Redis + Worker)
resource "aws_instance" "b_redis_worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.sg_redis_worker.id]

  tags = merge(local.tags, { Name = "B-redis-worker" })
}

# C: Private subnet (Postgres)
resource "aws_instance" "c_postgres" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.sg_postgres.id]

  tags = merge(local.tags, { Name = "C-postgres" })
}
