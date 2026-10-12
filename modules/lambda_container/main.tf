locals {
  function_name   = join("-", compact([var.name_prefix, var.service, var.name]))
  repository_name = join("/", compact([var.ecr_prefix, var.service, var.name]))
}

# ---------------------------------------------------------------- ECR
# The repository is created by the lambdas repository (coika-disaster_recovery, terraform/), which
# also pushes the images. It must exist, with an image under `image_tag`, before this module is
# applied: a function from an image cannot be created otherwise.

data "aws_ecr_repository" "this" {
  name = local.repository_name
}

data "aws_ecr_image" "this" {
  repository_name = data.aws_ecr_repository.this.name
  image_tag       = var.image_tag
}

# The repository and its lifecycle policy used to be defined here. Forget them without destroying
# them (the lambdas repository imports and owns them now); delete these blocks once applied.
removed {
  from = aws_ecr_repository.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ecr_lifecycle_policy.this

  lifecycle {
    destroy = false
  }
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
  image_uri     = "${data.aws_ecr_repository.this.repository_url}:${var.image_tag}"
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
    data.aws_ecr_image.this,
  ]

  # New images are rolled out by CI (aws lambda update-function-code),
  # so Terraform must not revert the function to `image_tag` on every apply.
  lifecycle {
    ignore_changes = [image_uri]
  }
}

# ---------------------------------------------------------------- Schedule (optional)

resource "aws_cloudwatch_event_rule" "schedule" {
  count = var.schedule_expression == null ? 0 : 1

  name                = "${local.function_name}-schedule"
  description         = "Runs ${local.function_name} on a schedule."
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "schedule" {
  count = var.schedule_expression == null ? 0 : 1

  rule = aws_cloudwatch_event_rule.schedule[0].name
  arn  = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "schedule" {
  count = var.schedule_expression == null ? 0 : 1

  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[0].arn
}