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

module "auth_service_health_check" {
  source = "./modules/lambda_container"

  name_prefix = var.name_prefix
  ecr_prefix  = var.ecr_prefix
  service     = "auth_service"
  name        = "health_check"

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
