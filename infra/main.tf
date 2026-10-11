# One module call per lambda in lambdas/<service>/<name>/.

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
