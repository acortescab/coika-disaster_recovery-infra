variable "name_prefix" {
  description = "Prefix of the function, IAM role and log group names (no slashes allowed)."
  type        = string
}

variable "ecr_prefix" {
  description = "Prefix of the ECR repository name (slashes allowed). Must match ECR_REPOSITORY_PREFIX in GitHub."
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
  description = "Image tag used when the function is first created. Later rollouts are done by CI."
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

variable "schedule_expression" {
  description = "EventBridge schedule, e.g. \"rate(1 minute)\". Null means no schedule."
  type        = string
  default     = null
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

variable "ecr_images_to_keep" {
  description = "Number of images kept in the ECR repository."
  type        = number
  default     = 10
}
