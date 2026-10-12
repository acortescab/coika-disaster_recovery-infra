output "health_check_function_name" {
  value = module.auth_service_health_check.function_name
}

output "region_check_repository_url" {
  value = module.auth_service_region_check.repository_url
}

output "failback_state_machine_arn" {
  description = "Start the failback with: aws stepfunctions start-execution --state-machine-arn <this>"
  value       = aws_sfn_state_machine.failback.arn
}

output "failover_state_table" {
  description = "DynamoDB table with the region that serves (and the failover lock)."
  value       = aws_dynamodb_table.failover_state.name
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
