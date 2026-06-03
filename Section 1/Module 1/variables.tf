variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for worker nodes"
  type        = list(string)
}

variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    spot           = bool
    taints         = map(string)
  }))
  default = {}
}

variable "addons" {
  description = "EKS add-ons to install"
  type = map(object({
    version = string
  }))
  default = {
    vpc-cni = { version = "latest" }
    coredns = { version = "latest" }
    kube-proxy = { version = "latest" }
  }
}
