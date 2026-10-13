# Role used by the `terraform-apply` job of cd.yml. It can only be assumed from the GitHub
# environment `prod`, whose required reviewers act as the approval gate.
#
# It is NOT a full admin: writes are limited to the resources this repo manages (prefix
# `coika`). IAM is the sensitive part: the pipeline only creates roles that carry the permissions
# boundary of iam_boundary.tf, and an explicit Deny keeps it from changing this role, the plan role or
# the boundary. Changes to github_oidc*.tf and iam_boundary.tf are therefore applied by an
# administrator from a workstation, never by the pipeline (the pipeline's apply of such a change fails
# with AccessDenied, by design).

data "aws_iam_policy_document" "github_apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_sub_prefix}:environment:${var.github_apply_environment}"]
    }

    # The `sub` of an environment job carries no branch: without these two, a workflow of any branch
    # that targets the environment (once a reviewer approves it) would get the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/${var.github_apply_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = ["${var.github_repository}/.github/workflows/${var.github_apply_workflow}@refs/heads/${var.github_apply_branch}"]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  name               = "coika-disaster_recovery-apply-role"
  assume_role_policy = data.aws_iam_policy_document.github_apply_assume.json
}

# Needed by `plan`/refresh of every resource type.
resource "aws_iam_role_policy_attachment" "github_apply_read_only" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_apply_permissions" {
  # --- Terraform state
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  # --- State bucket of the auth service in the DR region (the only bucket this stack creates)
  statement {
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketTagging",
    ]
    resources = ["arn:aws:s3:::${var.service_state_bucket}"]
  }

  # --- IAM roles of this project
  # Roles can only be created, deleted or given policies while they carry the pipeline boundary
  # (iam_boundary.tf), which caps whatever the pipeline writes into them.
  statement {
    sid = "RolesWithBoundary"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.pipeline_boundary.arn]
    }
  }

  statement {
    sid = "RolesOther"
    actions = [
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }

  # Only these managed policies can be attached (no AdministratorAccess), and only to roles with the boundary.
  statement {
    sid       = "RoleManagedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.pipeline_boundary.arn]
    }
  }

  # The pipeline cannot change its own access: the plan and apply roles are managed by an administrator
  # (their names match the prefix, so the Allows above would otherwise cover them), and the boundary
  # can never be removed from a role.
  statement {
    sid    = "DenyPipelineSelfChange"
    effect = "Deny"
    actions = [
      "iam:UpdateRole",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      aws_iam_role.github_plan.arn,
      aws_iam_role.github_apply.arn,
    ]
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "codebuild.amazonaws.com", "states.amazonaws.com"]
    }
  }

  # --- State machines (failover, failback) and their log groups
  statement {
    actions   = ["states:*"]
    resources = ["arn:aws:states:${var.dr_region}:${local.account_id}:stateMachine:${var.name_prefix}-*"]
  }

  statement {
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/vendedlogs/states/${var.name_prefix}-*",
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/vendedlogs/states/${var.name_prefix}-*:*",
    ]
  }

  # Log delivery of a state machine; these actions do not support resource-level scoping.
  statement {
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  # --- Failover CodeBuild project
  statement {
    actions   = ["codebuild:*"]
    resources = ["arn:aws:codebuild:${var.dr_region}:${local.account_id}:project/${var.name_prefix}-*"]
  }

  statement {
    actions = [
      "codeconnections:CreateConnection",
      "codeconnections:DeleteConnection",
      "codeconnections:GetConnection",
      "codeconnections:ListTagsForResource",
      "codeconnections:TagResource",
      "codeconnections:UntagResource",
    ]
    resources = ["arn:aws:codeconnections:${var.dr_region}:${local.account_id}:connection/*"]
  }

  statement {
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/codebuild/${var.name_prefix}-*",
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/codebuild/${var.name_prefix}-*:*",
    ]
  }

  # --- Lambda, ECR, logs
  statement {
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${var.dr_region}:${local.account_id}:function:${var.name_prefix}-*"]
  }

  # The repositories belong to the lambdas repository; creating a function from an image only
  # needs to read it. The repository policy actions let Lambda grant itself pull access to the image
  # when the function is created (without them: "Lambda does not have permission to access the ECR image").
  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:SetRepositoryPolicy",
    ]
    resources = ["arn:aws:ecr:${var.dr_region}:${local.account_id}:repository/${var.ecr_prefix}/*"]
  }

  statement {
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-*",
      "arn:aws:logs:${var.dr_region}:${local.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*",
    ]
  }

  # --- Alarms and notifications
  statement {
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["arn:aws:cloudwatch:${var.dr_region}:${local.account_id}:alarm:${var.name_prefix}-*"]
  }

  statement {
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = ["arn:aws:events:${var.dr_region}:${local.account_id}:rule/${var.name_prefix}-*"]
  }

  statement {
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:${var.dr_region}:${local.account_id}:table/${var.name_prefix}-*"]
  }

  statement {
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:${var.dr_region}:${local.account_id}:${var.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "github_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.github_apply_permissions.json
}
