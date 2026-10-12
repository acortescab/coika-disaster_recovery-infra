output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "repository_url" {
  value = data.aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = data.aws_ecr_repository.this.arn
}
