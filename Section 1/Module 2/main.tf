# modules/vpc-multi-region/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "clevertap-${var.environment}-${var.region}"
    Environment = var.environment
    Region      = var.region
  }
}

# Public subnets (for NAT Gateways, load balancers)
resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)
  availability_zone = "${var.region}${count.index == 0 ? "a" : "b"}"
  map_public_ip_on_launch = true

  tags = {
    Name = "clevertap-${var.environment}-public-${count.index}"
    Tier = "Public"
  }
}

# Private subnets (for EKS nodes, RDS)
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 2)
  availability_zone = "${var.region}${count.index == 0 ? "a" : "b"}"

  tags = {
    Name = "clevertap-${var.environment}-private-${count.index}"
    Tier = "Private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Intra subnets (for databases – no internet route)
resource "aws_subnet" "intra" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 4)
  availability_zone = "${var.region}${count.index == 0 ? "a" : "b"}"

  tags = {
    Name = "clevertap-${var.environment}-intra-${count.index}"
    Tier = "Intra"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = { Name = "clevertap-${var.environment}-igw" }
}

# NAT Gateways (one per AZ for high availability)
resource "aws_eip" "nat" {
  count = 2
  domain = "vpc"
  tags = { Name = "clevertap-${var.environment}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = 2

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "clevertap-${var.environment}-nat-${count.index}" }
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "clevertap-${var.environment}-public-rt" }
}

resource "aws_route_table" "private" {
  count = 2

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = { Name = "clevertap-${var.environment}-private-rt-${count.index}" }
}

# Intra route table – no default route
resource "aws_route_table" "intra" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "clevertap-${var.environment}-intra-rt" }
}

# Route table associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "intra" {
  count          = 2
  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra.id
}

# VPC Peering (if peer VPC ID provided)
resource "aws_vpc_peering_connection" "cross_region" {
  count = var.peer_vpc_id != null ? 1 : 0

  vpc_id      = aws_vpc.this.id
  peer_vpc_id = var.peer_vpc_id
  peer_region = var.peer_region
  auto_accept = true

  tags = { Name = "clevertap-${var.environment}-peering" }
}

# Add routes to peer VPC (update both sides – shown for this VPC)
resource "aws_route" "peer" {
  count = (var.peer_vpc_id != null ? length(aws_subnet.private) : 0)

  route_table_id            = aws_route_table.private[count.index].id
  destination_cidr_block    = var.peer_vpc_cidr  # Pass as variable
  vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
}

# VPC Flow Logs to S3 with lifecycle
resource "aws_s3_bucket" "flow_logs" {
  bucket = "clevertap-vpc-flow-logs-${var.environment}-${var.region}"
  force_destroy = false

  lifecycle_rule {
    enabled = true
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_flow_log" "vpc" {
  log_destination      = aws_s3_bucket.flow_logs.arn
  log_destination_type = "s3"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id

  tags = { Name = "clevertap-${var.environment}-flowlog" }
}
