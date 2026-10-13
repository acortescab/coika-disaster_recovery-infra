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
  description = "Prefix of the OIDC `sub` claim of the GitHub repository allowed to assume the CI roles. This repo uses immutable subjects (owner and repo IDs); get it with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`. The apply role also requires the branch and workflow below."
  type        = string
  default     = "repo:acortescab@289379741/coika-disaster_recovery-infra@1414221119"
}

variable "github_apply_environment" {
  description = "GitHub environment (with required reviewers) that is allowed to assume the apply role."
  type        = string
  default     = "prod"
}

variable "github_repository" {
  description = "GitHub repository (`owner/name`) of this infrastructure; used to build the `job_workflow_ref` the apply role trusts."
  type        = string
  default     = "acortescab/coika-disaster_recovery-infra"
}

variable "github_apply_branch" {
  description = "Only workflow runs on this branch can assume the apply role."
  type        = string
  default     = "main"
}

variable "github_apply_workflow" {
  description = "Workflow file (under .github/workflows/) that is the only one allowed to assume the apply role."
  type        = string
  default     = "cd.yml"
}

variable "service_state_bucket" {
  description = "DR-region S3 bucket that holds the Terraform state of the auth service (coika-auth_service-infra) when it runs in the DR region."
  type        = string
  default     = "coika-auth-tfstate-s3-290294660813-eu-central-1-an"
}

variable "service_repo_url" {
  description = "Public GitHub repository of the auth service infrastructure that the failover build runs."
  type        = string
  default     = "https://github.com/acortescab/coika-auth_service-infra.git"
}

variable "service_repo_ref" {
  description = "Branch, tag or commit of the service repository that the failover build checks out."
  type        = string
  default     = "main"
}

variable "service_ssh_public_key" {
  description = "SSH public key for the key pair that the auth service creates in the DR region (public, not a secret)."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICHdpdsU3YKeb31D5HTFwrOX1iiV7gw28PoA4LL2mfVw coika-auth_service"
}

variable "terraform_version" {
  description = "Terraform version installed in the failover build."
  type        = string
  default     = "1.15.5"
}

variable "failover_validation_attempts" {
  description = "Consecutive failed health re-checks required before the automatic failover starts. A single healthy answer cancels it as a false alarm."
  type        = number
  default     = 3
}

variable "failover_validation_interval_seconds" {
  description = "Seconds to wait between the health re-checks of the failover validation."
  type        = number
  default     = 30
}

variable "primary_region" {
  description = "Primary region (where the services run). `region_check` probes the AWS service endpoints of this region to tell a regional outage from a local one."
  type        = string
  default     = "eu-west-1"
}

variable "region_probe_services" {
  description = "AWS services whose public endpoint in the primary region is probed by `region_check` (`<service>.<primary_region>.amazonaws.com`). Pick services that are independent of each other."
  type        = list(string)
  default     = ["sts", "ec2", "s3", "sqs"]
}

variable "region_probe_failures_required" {
  description = "How many of the probed endpoints must fail for the primary region to be considered down. Below this the outage is treated as local and no failover starts."
  type        = number
  default     = 3

  validation {
    condition     = var.region_probe_failures_required >= 1 && var.region_probe_failures_required <= length(var.region_probe_services)
    error_message = "region_probe_failures_required must be between 1 and the number of region_probe_services."
  }
}

variable "primary_recovery_interval_minutes" {
  description = "How often `primary_recovery_check` probes the primary region while the DR region serves."
  type        = number
  default     = 5
}

variable "primary_recovery_threshold" {
  description = "Consecutive healthy runs of `primary_recovery_check` before it notifies that a failback is possible (interval x threshold = time the primary must stay healthy)."
  type        = number
  default     = 12
}

variable "primary_recovery_health_url" {
  description = "Health endpoint of the backend in the PRIMARY region, also checked by `primary_recovery_check`. It must reach the primary backend directly, not a DNS name that now points to the DR region. Empty means only the AWS service endpoints of the primary region are probed."
  type        = string
  default     = ""
}

variable "failback_approval_timeout_seconds" {
  description = "How long the failback state machine waits for each manual confirmation (writes stopped in DR; traffic switched to the primary). On timeout the failback is aborted and the DR region keeps serving."
  type        = number
  default     = 86400
}

variable "failback_teardown_dr" {
  description = "Whether the failback state machine also runs the `-down` build to destroy the auth service in the DR region once traffic is back on the primary. When false it only notifies, and `-down` is started by hand."
  type        = bool
  default     = false
}

variable "db_instance_name" {
  description = "Name tag of the database EC2 instance of the auth service stack (its `db_instance_name`). The failover finds the DB host by it."
  type        = string
  default     = "coika-auth_service-db-instance"
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
