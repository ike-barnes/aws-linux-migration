locals {
  name = "migration-${var.environment}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = var.private_subnets # migrated workloads
  public_subnets  = var.public_subnets  # NAT / ALB only
  intra_subnets   = var.staging_subnets # MGN staging area: no internet route, endpoints only

  private_subnet_names = [for az in var.azs : "${local.name}-workload-${az}"]
  intra_subnet_names   = [for az in var.azs : "${local.name}-mgn-staging-${az}"]

  enable_nat_gateway     = !var.lab_mode # lab: no NAT (~$33/month each)
  single_nat_gateway     = false
  one_nat_gateway_per_az = !var.lab_mode # AZ-independent egress (Red Hat CDN, package repos)

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch = false

  # Lock down the default SG/NACL (CIS 5.x)
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 90

  private_subnet_tags = { Tier = "workload" }
  intra_subnet_tags   = { Tier = "mgn-staging" }
}

# ---------------------------------------------------------------------------
# Hybrid connectivity: attach to existing TGW (VPN / Direct Connect)
# ---------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.transit_gateway_id == null ? 0 : 1

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  dns_support = "enable"

  tags = { Name = "${local.name}-tgw-attachment" }
}

locals {
  # Workload + staging route tables need on-prem routes (replication traffic + app dependencies)
  hybrid_route_tables = concat(module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids)
  hybrid_routes = var.transit_gateway_id == null ? {} : {
    for pair in setproduct(range(length(local.hybrid_route_tables)), var.onprem_cidrs) :
    "${pair[0]}-${pair[1]}" => { rt_index = pair[0], cidr = pair[1] }
  }
}

resource "aws_route" "to_onprem" {
  for_each = local.hybrid_routes

  route_table_id         = local.hybrid_route_tables[each.value.rt_index]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
