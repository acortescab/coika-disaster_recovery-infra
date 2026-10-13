variable "name_prefix" {
  description = "Prefix of the function, IAM role and log group names (no slashes allowed)."
  type        = string
}

variable "ecr_prefix" {
  description = "Prefix of the ECR repository name (slashes allowed), created by the lambdas repository. Must match ECR_REPOSITORY_PREFIX in GitHub."
  type        = string
}

variable "service" {
  description = "Service the lambda belongs to (second level of lambdas/<service>/<name>)."
  type        = string
}

variable "name" {
  description = "Lambda name (folder name in lambdas/<service>/<name>)."
  type        = string
}

variable "image_tag" {
  description = "Image tag the function is first created from; it must already be pushed to ECR by the lambdas repository CD. Later rollouts are done by CI."
  type        = string
  default     = "latest"
}

variable "environment" {
  description = "Environment variables of the function."
  type        = map(string)
  default     = {}
}

variable "policy_statements" {
  description = "Extra IAM statements for the execution role (on top of CloudWatch Logs)."
  type = list(object({
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []
}

variable "permissions_boundary" {
  description = "ARN of the permissions boundary attached to the execution role."
  type        = string
  default     = null
}

variable "schedule_expression" {
  description = "EventBridge schedule, e.g. \"rate(1 minute)\". Null means no schedule."
  type        = string
  default     = null
}

variable "schedule_enabled" {
  description = "Initial state of the schedule rule. Terraform ignores the state afterwards, so something else (e.g. a state machine) can enable and disable the rule."
  type        = bool
  default     = true
}

variable "timeout" {
  type    = number
  default = 10
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "log_retention_days" {
  type    = number
  default = 30
}
