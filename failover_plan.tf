# Dry run of the failover build. It only checks that the `-up` CodeBuild project can clone the
# service repo, read its Terraform state in the DR region and produce a `terraform plan`.
#
# It is started by hand (AWS console or `aws stepfunctions start-execution`): nothing triggers it, and
# it is independent of the real failover state machine (stepfunctions.tf). It creates nothing and
# records nothing: no lock, no state table update, no recovery check, no restore, no notifications.
# It does not exercise those parts of the real failover either; only a real failover does.

resource "aws_cloudwatch_log_group" "failover_plan_sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-auth_service-failover_plan"
  retention_in_days = 30
}

resource "aws_iam_role" "failover_plan_sfn" {
  name                 = "${var.name_prefix}-auth_service-failover_plan-sfn-role"
  assume_role_policy   = data.aws_iam_policy_document.sfn_assume.json
  permissions_boundary = aws_iam_policy.pipeline_boundary.arn
}

data "aws_iam_policy_document" "failover_plan_sfn" {
  statement {
    actions   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.failover["up"].arn]
  }

  # Managed rule that Step Functions creates to wait for the build (.sync integration).
  statement {
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["arn:aws:events:${var.dr_region}:${local.account_id}:rule/StepFunctionsGetEventForCodeBuildStartBuildRule"]
  }

  # Needed by the log delivery configuration; these actions do not support resource-level scoping.
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
}

resource "aws_iam_role_policy" "failover_plan_sfn" {
  name   = "failover-plan"
  role   = aws_iam_role.failover_plan_sfn.id
  policy = data.aws_iam_policy_document.failover_plan_sfn.json
}

resource "aws_sfn_state_machine" "failover_plan" {
  name     = "${aws_sfn_state_machine.failover.name}_plan"
  role_arn = aws_iam_role.failover_plan_sfn.arn

  # Step Functions checks the permissions of the role when it saves the definition.
  depends_on = [aws_iam_role_policy.failover_plan_sfn]

  definition = jsonencode({
    Comment        = "Dry run of the failover build (terraform plan in the DR region). Manual only; creates and records nothing."
    StartAt        = "PlanBuild"
    TimeoutSeconds = 3600
    States = {
      PlanBuild = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.failover["up"].name
          EnvironmentVariablesOverride = [
            { Name = "TF_ACTION", Value = "plan", Type = "PLAINTEXT" },
          ]
        }
        ResultPath = null
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.buildError", Next = "PlanFailed" }]
        Next       = "PlanDone"
      }

      PlanDone = {
        Type    = "Succeed"
        Comment = "The build produced a plan. Nothing was created or recorded."
      }

      PlanFailed = {
        Type  = "Fail"
        Error = "PlanBuildFailed"
        Cause = "The build did not finish successfully; see the build logs. Nothing was created or recorded."
      }
    }
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = false
    log_destination        = "${aws_cloudwatch_log_group.failover_plan_sfn.arn}:*"
  }
}
