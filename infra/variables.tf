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

variable "github_sub_prefix" {
  description = "Prefix of the OIDC `sub` claim of the GitHub repository allowed to assume the CI role from the main branch. This repo uses immutable subjects (owner and repo IDs); get it with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`."
  type        = string
  default     = "repo:acortescab@289379741/coika-disaster_recovery@1414221119"
}

variable "github_apply_environment" {
  description = "GitHub environment (with required reviewers) that is allowed to assume the apply role."
  type        = string
  default     = "prod"
}

variable "service_state_bucket" {
  description = "DR-region S3 bucket that holds the Terraform state of the auth service (coika-auth_service-infra) when it runs in the DR region."
  type        = string
  default     = "coika-auth-tfstate-s3-290294660813-eu-central-1-an"
}

variable "state_bucket" {
  description = "S3 bucket that holds the Terraform state (same as the backend in versions.tf, which cannot use variables)."
  type        = string
  default     = "coika-dr-tfstate-s3"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set to false if the AWS account already has one (only one per account is allowed)."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email that receives the alarm notifications (the subscription must be confirmed from the email AWS sends)."
  type        = string
  sensitive   = true # keeps it out of plan output (the PR comment is public)
}

variable "health_check_url" {
  description = "Backend health endpoint checked by auth_service/health_check."
  type        = string
}
