# Launch templates for REPLATFORMED (rebuilt) instances.
# MGN rehost instances use MGN-generated launch templates (see docs/phase2 Day 11).

# RHEL 9 — Red Hat Cloud Access gold image (BYOL). Private share from Red Hat's
# publishing account; public AMIs from the same owner are license-included (blocked by SCP).
data "aws_ami" "rhel9_byos" {
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Access*"]
  }
  filter {
    name   = "is-public"
    values = ["false"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Rocky Linux 9 (official RESF AMIs)
data "aws_ami" "rocky9" {
  most_recent = true
  owners      = [var.rocky_ami_owner]

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9.*x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Amazon Linux 2023 (AWS-published SSM parameter)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ssm_agent_rpm = "https://s3.${var.region}.amazonaws.com/amazon-ssm-${var.region}/latest/linux_amd64/amazon-ssm-agent.rpm"

  base_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf -y install ${local.ssm_agent_rpm} || true
    systemctl enable --now amazon-ssm-agent
    grubby --update-kernel=ALL --args='nvme_core.io_timeout=4294967295' || true
  EOT

  rhel_user_data = <<-EOT
    ${local.base_user_data}
    # Register BYOL subscription with Red Hat (Cloud Access).
    # Prefer Satellite or an SSM State Manager association for production secrets handling.
    rhc connect --organization '${var.rhel_org_id}' --activation-key '${var.rhel_activation_key}' || \
      subscription-manager register --org='${var.rhel_org_id}' --activationkey='${var.rhel_activation_key}'
  EOT

  al2023_user_data = "#!/bin/bash\ngrubby --update-kernel=ALL --args='nvme_core.io_timeout=4294967295' || true\n"

  # Kept free of sensitive values so it is valid as a for_each argument
  template_images = {
    rhel9-byol = data.aws_ami.rhel9_byos.id
    rocky9     = data.aws_ami.rocky9.id
    al2023     = data.aws_ssm_parameter.al2023.insecure_value
  }
}

resource "aws_launch_template" "rebuild" {
  for_each = local.template_images

  name_prefix            = "${local.name}-${each.key}-"
  description            = "Replatform target: ${each.key}"
  image_id               = each.value
  instance_type          = var.default_instance_type
  update_default_version = true
  user_data = base64encode(
    each.key == "rhel9-byol" ? local.rhel_user_data :
    each.key == "al2023" ? local.al2023_user_data : local.base_user_data
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.migrated_ec2.name
  }

  vpc_security_group_ids = [aws_security_group.workload_baseline.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      OSTemplate = each.key
      Backup     = "daily"
      PatchGroup = "linux-${var.environment}"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { OSTemplate = each.key }
  }
}
