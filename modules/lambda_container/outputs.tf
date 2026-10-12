output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "schedule_rule_name" {
  description = "Name of the schedule rule, or null if the function has no schedule."
  value       = try(aws_cloudwatch_event_rule.schedule[0].name, null)
}

output "schedule_rule_arn" {
  value = try(aws_cloudwatch_event_rule.schedule[0].arn, null)
}

output "repository_url" {
  value = data.aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = data.aws_ecr_repository.this.arn
}
