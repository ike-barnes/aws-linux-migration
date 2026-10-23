# AWS Backup: daily recovery points for every instance tagged Backup=daily
resource "aws_backup_vault" "this" {
  name        = "${local.name}-vault"
  kms_key_arn = aws_kms_key.ebs.arn
}

resource "aws_backup_plan" "daily" {
  name = "${local.name}-daily"

  rule {
    rule_name         = "daily-0500-utc"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "tagged" {
  name         = "${local.name}-tagged-daily"
  plan_id      = aws_backup_plan.daily.id
  iam_role_arn = aws_iam_role.backup.arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "daily"
  }
}
