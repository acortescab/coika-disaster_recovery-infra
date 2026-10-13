# Permissions boundary of every role this repository creates (lambdas, state machines, EventBridge,
# the failover CodeBuild). The apply role of the pipeline (github_oidc_apply.tf) can only create or
# change roles that carry it, so whatever policy it writes into them is capped here: they can never
# manage IAM outside the auth service stack, whatever their inline policies say.
#
# It grants nothing by itself; the effective permissions are the intersection with each role's policies.
#
# The boundary and the plan/apply roles are NOT writable by the pipeline (explicit Deny in the apply
# role): changes to this file, github_oidc.tf and github_oidc_apply.tf are applied by an administrator
# with `terraform apply` from a workstation. That is the point: the pipeline cannot widen its own access.

resource "aws_iam_policy" "pipeline_boundary" {
  name        = "${var.name_prefix}-disaster_recovery-boundary"
  description = "Permissions boundary of the roles created by the coika-disaster_recovery-infra pipeline."
  policy      = data.aws_iam_policy_document.pipeline_boundary.json
}

data "aws_iam_policy_document" "pipeline_boundary" {
  # Any service except identity management. The role policies still decide what each role can do.
  statement {
    sid         = "AllExceptIdentity"
    not_actions = ["iam:*", "organizations:*", "account:*"]
    resources   = ["*"]
  }

  # Read access to IAM (Terraform refresh in the failover build, ReadOnlyAccess).
  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # IAM writes only inside the auth service stack that the failover build creates.
  statement {
    sid     = "ServiceStackIam"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.service_prefix}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.service_prefix}-*",
      "arn:aws:iam::${local.account_id}:policy/${local.service_prefix}-*",
    ]
  }
}
