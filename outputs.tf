output "health_check_function_name" {
  value = module.auth_service_health_check.function_name
}

output "region_check_repository_url" {
  value = module.auth_service_region_check.repository_url
}

output "github_apply_role_arn" {
  description = "Value for the AWS_APPLY_ROLE_ARN secret in GitHub."
  value       = aws_iam_role.github_apply.arn
}

output "github_plan_role_arn" {
  description = "Value for the AWS_PLAN_ROLE_ARN secret in GitHub."
  value       = aws_iam_role.github_plan.arn
}

output "health_check_repository_url" {
  value = module.auth_service_health_check.repository_url
}
