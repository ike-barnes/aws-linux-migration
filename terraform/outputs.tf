output "vpc_id" {
  value = module.vpc.vpc_id
}

output "workload_subnet_ids" {
  value = module.vpc.private_subnets
}

output "mgn_staging_subnet_id" {
  description = "Subnet for the MGN replication configuration template (public subnet in lab mode)."
  value       = var.lab_mode ? module.vpc.public_subnets[0] : module.vpc.intra_subnets[0]
}

output "mgn_data_plane_routing" {
  description = "Value for --data-plane-routing in create-replication-configuration-template."
  value       = var.lab_mode ? "PUBLIC_IP" : "PRIVATE_IP"
}

output "mgn_create_public_ip" {
  description = "Value for --create-public-ip in create-replication-configuration-template."
  value       = var.lab_mode
}

output "launch_subnet_id" {
  description = "Subnet for MGN test/cutover instances (public subnet in lab mode so SSM works without NAT)."
  value       = var.lab_mode ? module.vpc.public_subnets[0] : module.vpc.private_subnets[0]
}

output "mgn_replication_sg_id" {
  value = aws_security_group.mgn_replication.id
}

output "workload_baseline_sg_id" {
  value = aws_security_group.workload_baseline.id
}

output "app_example_sg_id" {
  value = aws_security_group.app_example.id
}

output "db_example_sg_id" {
  value = aws_security_group.db_example.id
}

output "ebs_kms_key_arn" {
  value = aws_kms_key.ebs.arn
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.migrated_ec2.name
}

output "mgn_agent_installer_role_arn" {
  value = aws_iam_role.mgn_agent_installer.arn
}

output "rebuild_launch_template_ids" {
  value = { for k, lt in aws_launch_template.rebuild : k => lt.id }
}

output "rhel9_byol_ami_id" {
  value = data.aws_ami.rhel9_byos.id
}
