# Private connectivity for MGN replication servers (intra subnets, no NAT),
# SSM-managed instances, and KMS/STS/Logs calls without traversing the internet.
# Lab mode: disabled (interface endpoints cost ~$7/month each per AZ).
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"
  count   = var.lab_mode ? 0 : 1

  vpc_id = module.vpc.vpc_id

  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpce-"
  security_group_description = "HTTPS to interface endpoints from VPC and on-prem"
  security_group_rules = {
    ingress_https_vpc = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
    ingress_https_onprem = {
      description = "HTTPS from on-prem (MGN agents via Route 53 Resolver inbound endpoint)"
      cidr_blocks = var.onprem_cidrs
    }
  }

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids)
        tags            = { Name = "${local.name}-s3" }
      }
    },
    {
      for svc in ["ssm", "ssmmessages", "ec2messages", "ec2", "mgn", "kms", "logs", "sts", "monitoring"] :
      svc => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = module.vpc.intra_subnets
        tags                = { Name = "${local.name}-${svc}" }
      }
    }
  )
}
