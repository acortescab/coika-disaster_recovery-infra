# One module call per lambda in lambdas/<service>/<name>/.

# Restores the newest dump on the DB host of this region (called by the failover state machine).
module "auth_service_restore_db" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "restore_db"

  timeout = 900 # the state machine calls it again while the restore is still running

  environment = {
    DB_INSTANCE_NAME = var.db_instance_name
  }

  policy_statements = [
    {
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    },
    {
      # The failback also restores into the DB host of the primary region.
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:aws:ssm:${var.dr_region}::document/AWS-RunShellScript",
        "arn:aws:ec2:${var.dr_region}:${local.account_id}:instance/*",
        "arn:aws:ssm:${var.primary_region}::document/AWS-RunShellScript",
        "arn:aws:ec2:${var.primary_region}:${local.account_id}:instance/*",
      ]
    },
    {
      actions   = ["ssm:GetCommandInvocation"]
      resources = ["*"]
    },
  ]
}

# Dumps the DB of the DR host and returns the key of the dump (called by the failback state machine);
# the snapshots bucket replicates it to the primary region.
module "auth_service_backup_db" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "backup_db"

  timeout = 900 # the state machine calls it again while the backup is still running

  environment = {
    DB_INSTANCE_NAME = var.db_instance_name
  }

  policy_statements = [
    {
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    },
    {
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:aws:ssm:${var.dr_region}::document/AWS-RunShellScript",
        "arn:aws:ec2:${var.dr_region}:${local.account_id}:instance/*",
      ]
    },
    {
      actions   = ["ssm:GetCommandInvocation"]
      resources = ["*"]
    },
  ]
}

# Tells a primary-region outage from a local one (called by the failover state machine): probes the
# public endpoints of several AWS services in the primary region. It needs no IAM permissions.
module "auth_service_region_check" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "region_check"

  timeout = 20 # the probes run in parallel, each with its own short timeout

  environment = {
    PRIMARY_REGION    = var.primary_region
    PROBE_SERVICES    = join(",", var.region_probe_services)
    MIN_FAILED_PROBES = tostring(var.region_probe_failures_required)
  }
}

# While the DR region serves, checks on a schedule whether the primary region is back and notifies once
# it has been healthy for long enough to consider a failback. It only reads/updates the failover state.
module "auth_service_primary_recovery_check" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "primary_recovery_check"

  # The rule is created DISABLED: the failover state machine enables it once the DR region serves and
  # the failback state machine disables it when the primary serves again (Terraform ignores the rule
  # state afterwards).
  schedule_expression = "rate(${var.primary_recovery_interval_minutes} minutes)"
  schedule_enabled    = false

  timeout = 30 # the probes run in parallel, each with its own short timeout

  environment = {
    STATE_TABLE        = aws_dynamodb_table.failover_state.name
    SNS_TOPIC_ARN      = aws_sns_topic.alerts.arn
    PRIMARY_REGION     = var.primary_region
    PROBE_SERVICES     = join(",", var.region_probe_services)
    PRIMARY_HEALTH_URL = var.primary_recovery_health_url
    RECOVERY_THRESHOLD = tostring(var.primary_recovery_threshold)
  }

  policy_statements = [
    {
      actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
      resources = [aws_dynamodb_table.failover_state.arn]
    },
    {
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.alerts.arn]
    },
  ]
}

module "auth_service_health_check" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "health_check"

  # Starts the whole failover process: it publishes the BackendHealth metric that the alarm watches.
  # Disabled while the process is started by hand: uncomment to run it on a schedule. Before doing so,
  # see the alarm: its period is 60 s and missing data counts as breaching, so a 5-minute schedule
  # would leave the alarm in ALARM between runs.
  # schedule_expression = "rate(1 minute)"

  environment = {
    HEALTH_URL = var.health_check_url
  }

  policy_statements = [{
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    conditions = [{
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Coika/DisasterRecovery"]
    }]
  }]
}
