# us-east-1 production
module "vpc_use1" {
  source     = "./modules/vpc-multi-region"
  region     = "us-east-1"
  cidr_block = "10.0.0.0/16"
  environment = "prod"
  peer_vpc_id = module.vpc_aps1.vpc_id
  peer_region = "ap-south-1"
  peer_vpc_cidr = "10.1.0.0/16"
}

module "eks_use1" {
  source = "./modules/eks-cluster"
  cluster_name = "clevertap-prod-use1"
  vpc_id = module.vpc_use1.vpc_id
  private_subnet_ids = module.vpc_use1.private_subnet_ids

  node_groups = {
    "event-ingestion" = {
      instance_types = ["m5.xlarge", "m5a.xlarge"]
      desired_size   = 10
      min_size       = 8
      max_size       = 30
      spot           = false
      taints         = {}
    }
    "batch-spot" = {
      instance_types = ["c5.xlarge", "c5a.xlarge"]
      desired_size   = 20
      min_size       = 10
      max_size       = 50
      spot           = true
      taints = { "workload-type" = "batch" }
    }
  }
}
