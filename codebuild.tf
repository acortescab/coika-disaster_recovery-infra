# Failover build: runs `terraform` of the auth service repo (coika-auth_service-infra) in the DR
# region. It uses its own state (key `regions/<region>/terraform.tfstate`) in the DR-region bucket
# from service_state.tf, so it does not depend on anything in the primary region.
#
# Two projects: `-up` runs `terraform plan` by default and applies when started with the override
# TF_ACTION=apply; `-down` runs `terraform destroy`.

locals {
  failover_project_name = "${var.name_prefix}-auth_service-failover"
  state_key             = "regions/${var.dr_region}/terraform.tfstate"

  # Names used by the service stack (project_name and ecr_repository_name defaults).
  service_prefix     = "${var.name_prefix}-auth_service"
  service_ecr_prefix = var.name_prefix

  # <project_name with "_" replaced by "-">-db-snapshots-<account>-<region>, as built by the service stack (s3.tf).
  db_snapshots_bucket_name = "${replace(local.service_prefix, "_", "-")}-db-snapshots-${local.account_id}-${var.dr_region}"
  db_snapshots_bucket_arn  = "arn:aws:s3:::${local.db_snapshots_bucket_name}"
}

resource "aws_cloudwatch_log_group" "failover" {
  name              = "/aws/codebuild/${local.failover_project_name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "failover_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "failover" {
  name                 = "${local.failover_project_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.failover_assume.json
  permissions_boundary = aws_iam_policy.pipeline_boundary.arn
}

# Enough to plan any resource type. Write permissions are added when apply is enabled.
resource "aws_iam_role_policy_attachment" "failover_read_only" {
  role       = aws_iam_role.failover.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "failover_permissions" {
  statement {
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      aws_cloudwatch_log_group.failover.arn,
      "${aws_cloudwatch_log_group.failover.arn}:*",
    ]
  }

  statement {
    actions   = ["codeconnections:GetConnectionToken", "codeconnections:GetConnection", "codeconnections:UseConnection"]
    resources = [aws_codeconnections_connection.github.arn]
  }

  # Service state (and the native lockfile).
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.service_state.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.service_state.arn}/*"]
  }

  # --- What the service stack creates (mirrors its own CI apply role, ci_iam.tf), DR region only.
  statement {
    sid = "Ec2"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:ModifyInstanceCreditSpecification",
      "ec2:MonitorInstances",
      "ec2:UnmonitorInstances",
      "ec2:ModifyVolume",
      "ec2:AssociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation",
      "ec2:DisassociateIamInstanceProfile",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:ImportKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:CreateNatGateway",
      "ec2:DeleteNatGateway",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.dr_region]
    }
  }

  # DB snapshots bucket. In DR it is the replica of the primary bucket: the build adopts it
  # (terraform import) and never deletes it (see the buildspecs).
  statement {
    sid = "DbSnapshotsBucket"
    actions = [
      "s3:CreateBucket",
      "s3:ListBucket",
      "s3:GetBucket*",
      "s3:PutBucket*",
      "s3:Get*Configuration",
      "s3:Put*Configuration",
    ]
    resources = [local.db_snapshots_bucket_arn]
  }

  # Non-secret parameters of the service (DB_HOST, DB_PORT); the secrets are created by hand.
  statement {
    sid = "SsmParameters"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
    ]
    resources = ["arn:aws:ssm:${var.dr_region}:${local.account_id}:parameter/${local.service_prefix}/*"]
  }

  statement {
    sid = "EcrRepository"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:PutImageTagMutability",
      "ecr:PutImageScanningConfiguration",
    ]
    resources = ["arn:aws:ecr:${var.dr_region}:${local.account_id}:repository/${local.service_ecr_prefix}/*"]
  }

  # IAM is global, so it is limited by name and by the service's permissions boundary instead of region.
  statement {
    sid = "IamRolesAndProfiles"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.service_prefix}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.service_prefix}-*",
    ]
  }

  # Roles can only be created with the service's boundary attached.
  statement {
    sid       = "IamCreateRoleWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.service_prefix}-*"]

    condition {
      test     = "StringLike"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:aws:iam::${local.account_id}:policy/${local.service_prefix}-ci-boundary*"]
    }
  }

  statement {
    sid       = "IamBoundaryPolicy"
    actions   = ["iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"]
    resources = ["arn:aws:iam::${local.account_id}:policy/${local.service_prefix}-ci-boundary*"]
  }

  statement {
    sid       = "IamManagedPolicyAttachments"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.service_prefix}-*"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
      ]
    }
  }

  # The service prefix (coika-auth_service-*) also matches the roles of this repository (lambdas, state
  # machines, this build). Their policies cannot be changed from here: they carry the pipeline boundary.
  statement {
    sid    = "DenyPolicyChangesOnPipelineRoles"
    effect = "Deny"
    actions = [
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.pipeline_boundary.arn]
    }
  }

  statement {
    sid       = "IamPassRoleToEc2"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.service_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "failover" {
  name   = "failover"
  role   = aws_iam_role.failover.id
  policy = data.aws_iam_policy_document.failover_permissions.json
}

# One project per direction, each with its own buildspec: starting `-down` is a deliberate act and
# cannot happen by mistyping a parameter of `-up`.
locals {
  failover_projects = {
    up = {
      description = "Brings up the auth service in the DR region (TF_ACTION=plan by default; the failover state machine overrides it with apply, the dry-run one with plan)."
      buildspec   = "buildspec-up.yml"
      tf_action   = "plan"
    }
    down = {
      description = "Tears down the auth service in the DR region (terraform destroy; keeps the ECR repository)."
      buildspec   = "buildspec-down.yml"
      tf_action   = "destroy"
    }
  }
}

resource "aws_codebuild_project" "failover" {
  for_each = local.failover_projects

  name         = "${local.failover_project_name}-${each.key}"
  description  = each.value.description
  service_role = aws_iam_role.failover.arn

  build_timeout = 30 # minutes

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TF_VERSION"
      value = var.terraform_version
    }
    environment_variable {
      name  = "TF_ACTION"
      value = each.value.tf_action
    }
    environment_variable {
      name  = "STATE_BUCKET"
      value = aws_s3_bucket.service_state.bucket
    }
    environment_variable {
      name  = "STATE_KEY"
      value = local.state_key
    }
    environment_variable {
      name  = "DR_REGION"
      value = var.dr_region
    }
    environment_variable {
      name  = "DB_SNAPSHOTS_BUCKET"
      value = local.db_snapshots_bucket_name
    }

    # Variables of the service stack (TF_VAR_*). The rest keep the defaults of its repository.
    environment_variable {
      name  = "TF_VAR_aws_region"
      value = var.dr_region
    }
    environment_variable {
      name  = "TF_VAR_ecr_replication_regions" # a region cannot replicate to itself
      value = "[]"
    }
    environment_variable {
      name  = "TF_VAR_tfstate_bucket_name" # the CI roles created in DR read the DR state
      value = aws_s3_bucket.service_state.bucket
    }
    environment_variable {
      name  = "TF_VAR_ssh_public_key"
      value = var.service_ssh_public_key
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.failover.name
    }
  }

  # The service repo may be private: it is cloned through the connection of this region, not the
  # account's default one (which lives in another region).
  source {
    type            = "GITHUB"
    location        = var.service_repo_url
    git_clone_depth = 1

    auth {
      type     = "CODECONNECTIONS"
      resource = aws_codeconnections_connection.github.arn
    }

    # Inline buildspec: the cloned service repo does not know about the DR flow.
    buildspec = file("${path.module}/failover/${each.value.buildspec}")
  }

  source_version = var.service_repo_ref
}

# GitHub App connection in the DR region. It is created PENDING: authorize it once in the console
# (Developer Tools > Settings > Connections > Update pending connection) before the first build.
resource "aws_codeconnections_connection" "github" {
  name          = "${var.name_prefix}-github"
  provider_type = "GitHub"
}
