variable "region" {
  description = "Target AWS region (must match the Migration Hub home region decision)."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "prod"
}

variable "repository" {
  description = "Git repository that owns this stack (tag value)."
  type        = string
  default     = "<org>/<repo>"
}

variable "vpc_cidr" {
  description = "Target VPC CIDR. Must not overlap any on-premises range."
  type        = string
  default     = "10.60.0.0/16"
}

variable "azs" {
  description = "Availability zones (>= 2)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two AZs are required."
  }
}

variable "private_subnets" {
  description = "Workload subnets (migrated EC2 instances). One per AZ."
  type        = list(string)
  default     = ["10.60.0.0/20", "10.60.16.0/20"]
}

variable "public_subnets" {
  description = "Public subnets for NAT gateways / ALBs only. One per AZ."
  type        = list(string)
  default     = ["10.60.240.0/24", "10.60.241.0/24"]
}

variable "staging_subnets" {
  description = "MGN staging-area subnets (replication servers). No internet route. One per AZ."
  type        = list(string)
  default     = ["10.60.200.0/24", "10.60.201.0/24"]
}

variable "onprem_cidrs" {
  description = "On-premises source ranges allowed to replicate (TCP 1500) and reach endpoints (TCP 443)."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "transit_gateway_id" {
  description = "Existing Transit Gateway providing VPN/Direct Connect to on-prem. null to skip attachment."
  type        = string
  default     = null
}

variable "app_ingress_ports" {
  description = "TCP ports opened on the example app SG from on-prem CIDRs. Replace with per-app SGs."
  type        = list(number)
  default     = [443]
}

variable "rhel_org_id" {
  description = "Red Hat organization ID used by rhc/subscription-manager on rebuilt RHEL instances."
  type        = string
  default     = ""
  sensitive   = true
}

variable "rhel_activation_key" {
  description = "Red Hat activation key name. Stored in user data: restrict ec2:DescribeInstanceAttribute."
  type        = string
  default     = ""
  sensitive   = true
}

variable "rocky_ami_owner" {
  description = "AWS account that publishes official Rocky Linux AMIs. Verify against rockylinux.org before use."
  type        = string
  default     = "792107900819"
}

variable "default_instance_type" {
  description = "Default instance type for rebuild launch templates (Nitro family)."
  type        = string
  default     = "m7i.large"
}

variable "lab_mode" {
  description = "Practice-lab mode: no NAT gateways, no interface endpoints; MGN staging uses the public subnet with public IPs. Never use for production."
  type        = bool
  default     = false
}

variable "budget_email" {
  description = "Email for AWS Budget alerts. Empty string disables the budget."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 30
}

variable "mgn_installer_principal_pattern" {
  description = "ARN pattern of principals allowed to assume the MGN agent-installer role."
  type        = string
  default     = "role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_MigrationEngineer_*"
}

variable "backup_retention_days" {
  description = "Daily recovery point retention in AWS Backup."
  type        = number
  default     = 35
}
