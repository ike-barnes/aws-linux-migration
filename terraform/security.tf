# ---------------------------------------------------------------------------
# KMS: customer-managed key for all EBS (MGN staging + migrated instances)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Lets MGN service roles, Backup and EC2 use the key only through EC2/EBS in this account
  statement {
    sid = "AllowEbsUseViaEc2"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
      "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "EBS encryption for migrated Linux workloads and MGN staging"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ebs_kms.json
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  key_arn = aws_kms_key.ebs.arn
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# MGN replication servers: TCP 1500 from on-prem agents only
resource "aws_security_group" "mgn_replication" {
  name_prefix = "${local.name}-mgn-replication-"
  description = "MGN replication servers (staging area)"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "mgn_replication_1500" {
  for_each          = toset(var.onprem_cidrs)
  security_group_id = aws_security_group.mgn_replication.id
  description       = "MGN agent data replication"
  ip_protocol       = "tcp"
  from_port         = 1500
  to_port           = 1500
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "mgn_replication_https" {
  security_group_id = aws_security_group.mgn_replication.id
  description       = "HTTPS to VPC endpoints / S3 gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Baseline for every migrated instance: no inbound (SSM only), HTTPS egress
resource "aws_security_group" "workload_baseline" {
  name_prefix = "${local.name}-workload-baseline-"
  description = "Baseline for migrated Linux instances: no ingress, HTTPS egress"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "workload_https" {
  security_group_id = aws_security_group.workload_baseline.id
  description       = "SSM, Red Hat CDN, package repos, AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "workload_http" {
  security_group_id = aws_security_group.workload_baseline.id
  description       = "Package repos served over HTTP (GPG-signed): CentOS vault, Ubuntu archive"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "workload_mysql_vpc" {
  security_group_id = aws_security_group.workload_baseline.id
  description       = "App tier to database tier inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = var.vpc_cidr
}

# Example database SG: MySQL/MariaDB only from instances carrying the workload baseline SG
resource "aws_security_group" "db_example" {
  name_prefix = "${local.name}-db-example-"
  description = "Example DB tier: 3306 from app tier only"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db_example.id
  description                  = "MariaDB from app tier"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.workload_baseline.id
}

resource "aws_vpc_security_group_egress_rule" "workload_onprem" {
  for_each          = toset(var.onprem_cidrs)
  security_group_id = aws_security_group.workload_baseline.id
  description       = "Hybrid dependencies to on-prem (tighten per app)"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

# Example application SG — duplicate per app with explicit ports and sources
resource "aws_security_group" "app_example" {
  name_prefix = "${local.name}-app-example-"
  description = "Example app ingress from on-prem users"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "app_example" {
  for_each = {
    for pair in setproduct(var.app_ingress_ports, var.onprem_cidrs) : "${pair[0]}-${pair[1]}" => {
      port = pair[0]
      cidr = pair[1]
    }
  }
  security_group_id = aws_security_group.app_example.id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}
