# ---------------------------------------------------------------------------
# Instance role for every migrated / rebuilt EC2 instance
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "migrated_ec2" {
  name               = "migrated-ec2-ssm"
  description        = "SSM + CloudWatch agent for migrated Linux instances"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "migrated_ec2" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.migrated_ec2.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "migrated_ec2" {
  name = "migrated-ec2-ssm"
  role = aws_iam_role.migrated_ec2.name
}

# ---------------------------------------------------------------------------
# MGN agent installer role: assumed for <= 1 h by migration engineers (SSO)
# to mint temporary credentials for aws-replication-installer-init.
# Replaces long-lived IAM user access keys.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "mgn_installer_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:${var.mgn_installer_principal_pattern}"
      ]
    }
  }
}

resource "aws_iam_role" "mgn_agent_installer" {
  name                 = "mgn-agent-installer"
  description          = "Temporary credentials for MGN replication agent installation"
  assume_role_policy   = data.aws_iam_policy_document.mgn_installer_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "mgn_agent_installer" {
  role       = aws_iam_role.mgn_agent_installer.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSApplicationMigrationAgentInstallationPolicy"
}
