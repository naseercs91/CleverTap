variable "region" {
  description = "AWS region"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

variable "peer_vpc_id" {
  description = "ID of the VPC to peer with (from other region)"
  type        = string
  default     = null
}

variable "peer_region" {
  description = "Region of the peer VPC"
  type        = string
  default     = null
}

