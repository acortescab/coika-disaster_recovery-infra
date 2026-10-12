# Backend alarm goes to ALARM -> EventBridge -> Step Functions, which first re-checks the backend
# several times (any healthy answer = false alarm, stop) and only then starts the failover build
# (`-up`) in the DR region. It waits for the build (startBuild.sync) so the execution shows its result.

resource "aws_cloudwatch_log_group" "failover_sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-auth_service-failover"
  retention_in_days = 30
}

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "failover_sfn" {
  name               = "${var.name_prefix}-auth_service-failover-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "failover_sfn" {
  statement {
    actions   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.failover["up"].arn]
  }

  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [module.auth_service_health_check.function_arn]
  }

  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [module.auth_service_restore_db.function_arn]
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

resource "aws_iam_role_policy" "failover_sfn" {
  name   = "failover"
  role   = aws_iam_role.failover_sfn.id
  policy = data.aws_iam_policy_document.failover_sfn.json
}

locals {
  failover_states = {
    StartFailoverBuild = {
      Type     = "Task"
      Resource = "arn:aws:states:::codebuild:startBuild.sync"
      Parameters = {
        ProjectName = aws_codebuild_project.failover["up"].name
        EnvironmentVariablesOverride = [
          { Name = "TF_ACTION", Value = var.failover_tf_action, Type = "PLAINTEXT" },
        ]
      }
      ResultSelector = { "status.$" = "$.Build.BuildStatus", "arn.$" = "$.Build.Arn" }
      ResultPath     = "$.build"
      Next           = "StartRestore"
    }

    StartRestore = {
      Type       = "Pass"
      Result     = {}
      ResultPath = "$.restore"
      Next       = "RestoreDb"
    }

    # The lambda finds the DB host, runs the restore on it through SSM and waits. A lambda lives at most
    # 15 minutes, so while the restore is still running it answers InProgress with the ids to resume
    # with, and EvaluateRestore calls it again (the whole execution is bounded by TimeoutSeconds, and
    # the lambda gives up after MAX_WAIT_SECONDS).
    RestoreDb = {
      Type           = "Task"
      Resource       = "arn:aws:states:::lambda:invoke"
      TimeoutSeconds = 930
      Parameters = {
        FunctionName = module.auth_service_restore_db.function_arn
        "Payload.$"  = "$.restore"
      }
      ResultSelector = {
        "status.$"      = "$.Payload.status"
        "message.$"     = "$.Payload.message"
        "instance_id.$" = "$.Payload.instance_id"
        "command_id.$"  = "$.Payload.command_id"
        "started_at.$"  = "$.Payload.started_at"
      }
      ResultPath = "$.restore"
      Retry = [{
        ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
        IntervalSeconds = 2
        MaxAttempts     = 3
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.restoreError", Next = "RestoreFailed" }]
      Next  = "EvaluateRestore"
    }

    EvaluateRestore = {
      Type = "Choice"
      Choices = [
        { Variable = "$.restore.status", StringEquals = "Success", Next = "Restored" },
        { Variable = "$.restore.status", StringEquals = "InProgress", Next = "RestoreDb" },
        { Variable = "$.restore.status", StringEquals = "NoHost", Next = "NoDbHost" },
      ]
      Default = "RestoreFailed"
    }

    # With plan nothing is created, so the absence of a host is expected; with apply it is an error.
    NoDbHost = var.failover_tf_action == "apply" ? {
      Type  = "Fail"
      Error = "DbHostNotFound"
      Cause = "The deploy finished but there is no running database host to restore into."
    } : { Type = "Succeed" }

    Restored = { Type = "Succeed" }

    RestoreFailed = {
      Type  = "Fail"
      Error = "RestoreFailed"
      Cause = "The database could not be restored from the latest dump; see $.restore.message or the logs of the restore_db lambda."
    }
  }
}

resource "aws_sfn_state_machine" "failover" {
  name     = "${var.name_prefix}-auth_service-failover"
  role_arn = aws_iam_role.failover_sfn.arn

  definition = jsonencode({
    Comment        = "Confirms the backend is really down, brings up the auth service in the DR region and restores the latest dump."
    StartAt        = "InitChecks"
    TimeoutSeconds = 10800
    States = merge(local.failover_states, {
      InitChecks = {
        Type       = "Pass"
        Parameters = { attempt = 0 }
        Next       = "CheckHealth"
      }

      # The same lambda that feeds the alarm; it also publishes the metric, so a recovery is reflected there.
      CheckHealth = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.auth_service_health_check.function_arn
          Payload      = {}
        }
        ResultSelector = { "healthy.$" = "$.Payload.healthy" }
        ResultPath     = "$.check"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 2
          MaxAttempts     = 2
        }]
        # A broken checker is not proof of an outage: stop without failing over.
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "ValidationFailed" }]
        Next  = "EvaluateCheck"
      }

      EvaluateCheck = {
        Type    = "Choice"
        Choices = [{ Variable = "$.check.healthy", BooleanEquals = true, Next = "FalseAlarm" }]
        Default = "CountAttempt"
      }

      CountAttempt = {
        Type       = "Pass"
        Parameters = { "attempt.$" = "States.MathAdd($.attempt, 1)" }
        Next       = "MoreChecks"
      }

      MoreChecks = {
        Type    = "Choice"
        Choices = [{ Variable = "$.attempt", NumericLessThan = var.failover_validation_attempts, Next = "WaitBetweenChecks" }]
        Default = "StartFailoverBuild"
      }

      WaitBetweenChecks = {
        Type    = "Wait"
        Seconds = var.failover_validation_interval_seconds
        Next    = "CheckHealth"
      }

      FalseAlarm = {
        Type    = "Succeed"
        Comment = "The backend answered OK on a re-check: no failover."
      }

      ValidationFailed = {
        Type  = "Fail"
        Error = "HealthCheckFailed"
        Cause = "The health check lambda failed, so the outage could not be confirmed. No failover was started."
      }
    })
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = false
    log_destination        = "${aws_cloudwatch_log_group.failover_sfn.arn}:*"
  }
}

resource "aws_cloudwatch_event_rule" "backend_alarm_failover" {
  name        = "${var.name_prefix}-auth_service-failover-trigger"
  description = "Start the failover state machine when the backend alarm goes to ALARM."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.backend_unhealthy.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "failover_events" {
  name               = "${var.name_prefix}-auth_service-failover-events-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "failover_events" {
  name = "start-execution"
  role = aws_iam_role.failover_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.failover.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "failover" {
  rule     = aws_cloudwatch_event_rule.backend_alarm_failover.name
  arn      = aws_sfn_state_machine.failover.arn
  role_arn = aws_iam_role.failover_events.arn
}
