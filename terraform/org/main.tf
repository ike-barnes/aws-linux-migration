# Apply from the AWS Organizations MANAGEMENT account (separate state).
# Blocks launching Red Hat license-included (public) AMIs so RHEL runs only on
# Cloud Access gold images (BYOL). Gold images are private shares from the same
# Red Hat publishing account, so they are unaffected.
#
# Test against a sandbox OU first. MGN-launched rehost instances do not use
# Red Hat-owned AMIs and are unaffected.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "target_ou_id" {
  description = "OU (or account ID) to attach the SCP to. Start with a sandbox OU."
  type        = string
}

data "aws_iam_policy_document" "deny_rhel_license_included" {
  statement {
    sid       = "DenyRhelLicenseIncludedAmis"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*::image/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Owner"
      values   = ["309956199498"]
    }
    condition {
      test     = "Bool"
      variable = "ec2:Public"
      values   = ["true"]
    }
  }
}

resource "aws_organizations_policy" "deny_rhel_li" {
  name        = "deny-rhel-license-included-amis"
  description = "Enforce RHEL BYOL via Red Hat Cloud Access gold images"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_rhel_license_included.json
}

resource "aws_organizations_policy_attachment" "deny_rhel_li" {
  policy_id = aws_organizations_policy.deny_rhel_li.id
  target_id = var.target_ou_id
}

output "scp_policy_id" {
  value = aws_organizations_policy.deny_rhel_li.id
}
