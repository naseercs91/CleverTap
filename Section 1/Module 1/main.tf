terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false   # Private API server endpoint
    security_group_ids      = [aws_security_group.cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
  ]
}

# IAM Role for EKS cluster
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# Security group for cluster
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id
}

# Node group(s) – mixed On-Demand + Spot
resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  dynamic "launch_template" {
    for_each = each.value.spot ? [1] : []
    content {
      name = aws_launch_template.spot[each.key].name
    }
  }

  instance_types = each.value.instance_types
  capacity_type  = each.value.spot ? "SPOT" : "ON_DEMAND"

  taint {
    key    = "workload-type"
    value  = each.value.taints["workload-type"]
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name         = each.key
    NodeGroup    = each.key
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}

# Launch template for Spot node groups (eviction strategy)
resource "aws_launch_template" "spot" {
  for_each = { for k, v in var.node_groups : k => v if v.spot }

  name_prefix   = "${each.key}-spot-"
  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = each.value.instance_types[0]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${each.key}-spot"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    }
  }

  # Spot eviction strategy: add a node termination handler (managed by k8s)
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Install AWS Node Termination Handler
    kubectl apply -f https://github.com/aws/aws-node-termination-handler/releases/latest/download/all_aws_linux_amd64.yaml
  EOF
  )
}

data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2/recommended/image_id"
}

# IAM Role for worker nodes (IRSA foundation)
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# IRSA example: allow pods to assume IAM roles
resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# EKS Add-ons managed via Terraform
resource "aws_eks_addon" "this" {
  for_each = var.addons

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key
  addon_version = each.value.version == "latest" ? null : each.value.version
  resolve_conflicts_on_create = "OVERWRITE"
}
