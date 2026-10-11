# Failover build: runs `terraform` of the auth service repo (coika-auth_service-infra) in the DR
# region. It uses its own state (key `regions/<region>/terraform.tfstate`) in the DR-region bucket
# from service_state.tf, so it does not depend on anything in the primary region.
#
# Step 1: the build only runs `terraform plan` (TF_ACTION=plan). Applying is requested per
# execution with the environment variable override TF_ACTION=apply.

locals {
  failover_project_name = "${var.name_prefix}-auth_service-failover"
  state_key             = "regions/${var.dr_region}/terraform.tfstate"

  # Names used by the service stack (project_name and ecr_repository_name defaults).
  service_prefix     = "${var.name_prefix}-auth_service"
  service_ecr_prefix = var.name_prefix
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
  name               = "${local.failover_project_name}-role"
  assume_role_policy = data.aws_iam_policy_document.failover_assume.json
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
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.dr_region]
    }
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

resource "aws_codebuild_project" "failover" {
  name         = local.failover_project_name
  description  = "Brings up the auth service in the DR region by running its Terraform."
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
      value = "plan"
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


  source {
    type            = "GITHUB"
    location        = var.service_repo_url
    git_clone_depth = 1

    # Inline buildspec: the cloned service repo does not know about the DR flow.
    buildspec = file("${path.module}/failover/buildspec.yml")
  }

  source_version = var.service_repo_ref
}
