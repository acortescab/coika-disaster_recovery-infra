# Role used by the `terraform-apply` job of cd.yml. It can only be assumed from the GitHub
# environment `prod`, whose required reviewers act as the approval gate.
#
# It is NOT a full admin: writes are limited to the resources this repo manages (prefix
# `coika`), and it cannot modify itself or the plan role, so a bad merge cannot grant itself
# more permissions. Changes to those two roles must be applied from a workstation.

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
  statement {
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }

  # Only these managed policies can be attached (no AdministratorAccess).
  statement {
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
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "codebuild.amazonaws.com"]
    }
  }

  # --- Failover CodeBuild project
  statement {
    actions   = ["codebuild:*"]
    resources = ["arn:aws:codebuild:${var.dr_region}:${local.account_id}:project/${var.name_prefix}-*"]
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

  statement {
    actions   = ["ecr:*"]
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
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:${var.dr_region}:${local.account_id}:${var.name_prefix}-*"]
  }

  # --- This role and the plan role are off limits for the pipeline.
  statement {
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      aws_iam_role.github_apply.arn,
      aws_iam_role.github_plan.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.github_apply_permissions.json
}
