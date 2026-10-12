locals {
  function_name   = join("-", compact([var.name_prefix, var.service, var.name]))
  repository_name = join("/", compact([var.ecr_prefix, var.service, var.name]))
}

# ---------------------------------------------------------------- ECR

resource "aws_ecr_repository" "this" {
  name                 = local.repository_name
  image_tag_mutability = "MUTABLE" # CI also pushes a moving `latest` tag

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.ecr_images_to_keep} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_images_to_keep
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------- IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.function_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "extra" {
  count = length(var.policy_statements) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = var.policy_statements

    content {
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "extra" {
  count = length(var.policy_statements) > 0 ? 1 : 0

  name   = "permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.extra[0].json
}

# ---------------------------------------------------------------- Lambda

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  role          = aws_iam_role.this.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
  architectures = ["x86_64"]
  timeout       = var.timeout
  memory_size   = var.memory_size

  dynamic "environment" {
    for_each = length(var.environment) > 0 ? [1] : []

    content {
      variables = var.environment
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachment.logs,
  ]

  # New images are rolled out by CI (aws lambda update-function-code),
  # so Terraform must not revert the function to `image_tag` on every apply.
  lifecycle {
    ignore_changes = [image_uri]
  }
}