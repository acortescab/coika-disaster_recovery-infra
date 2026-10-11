variable "dr_region" {
  description = "Disaster recovery region. Everything in this repo is deployed here, never in the primary region, so it survives a primary region outage."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for function, IAM role and log group names (no slashes)."
  type        = string
  default     = "coika"
}

variable "ecr_prefix" {
  description = "Prefix for ECR repositories. Same value as the ECR_REPOSITORY_PREFIX GitHub variable."
  type        = string
  default     = "coika/disaster_recovery"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the CI role from the main branch."
  type        = string
  default     = "acortescab/coika-disaster_recovery"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set to false if the AWS account already has one (only one per account is allowed)."
  type        = bool
  default     = false
}

variable "health_check_url" {
  description = "Backend health endpoint checked by auth_service/health_check."
  type        = string
}
