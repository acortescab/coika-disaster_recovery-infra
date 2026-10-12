# Backend alarm goes to ALARM -> EventBridge -> Step Functions, which first re-checks the backend
# several times (any healthy answer = false alarm, stop), then checks that the whole primary region
# is impaired (if only the backend is down it emails and stops) and only then starts the failover
# build (`-up`) in the DR region. It waits for the build (startBuild.sync) so the execution shows its result.

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
    resources = [module.auth_service_region_check.function_arn]
  }

  # Restore of the DB through the backup+restore state machine (db_backup_restore.tf).
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.db_backup_restore.arn]
  }

  statement {
    actions   = ["states:DescribeExecution", "states:StopExecution"]
    resources = [local.db_backup_restore_executions_arn]
  }

  # Managed rule that Step Functions creates to wait for the nested execution (.sync integration).
  statement {
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["arn:aws:events:${var.dr_region}:${local.account_id}:rule/StepFunctionsGetEventsForStepFunctionsExecutionRule"]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.failover_state.arn]
  }

  # Lets a new execution tell whether the one that holds the failover lock is still running. The ARN is
  # built by hand: referencing the state machine here would make the role and the state machine depend on each other.
  statement {
    actions   = ["states:DescribeExecution"]
    resources = ["arn:aws:states:${var.dr_region}:${local.account_id}:execution:${var.name_prefix}-auth_service-failover:*"]
  }

  # Turns the primary recovery check on once the DR region serves (the failback turns it off).
  statement {
    actions   = ["events:EnableRule"]
    resources = [module.auth_service_primary_recovery_check.schedule_rule_arn]
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
          { Name = "TF_ACTION", Value = "apply", Type = "PLAINTEXT" },
        ]
      }
      ResultSelector = { "status.$" = "$.Build.BuildStatus", "arn.$" = "$.Build.Arn" }
      ResultPath     = "$.build"
      Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.buildError", Next = "MarkBuildFailed" }]
      Next           = "RunRestore"
    }

    BuildFailed = {
      Type  = "Fail"
      Error = "FailoverBuildFailed"
      Cause = "The failover build did not finish successfully; see the build logs. The failover state is FAILOVER_FAILED, so a new failover may start."
    }

    # Restores the newest dump on the DB host of the DR region (no backup). The restore replaces the data
    # of that DB: the lock guarantees this state machine only gets here while the DR is not serving. The
    # backup+restore state machine finds the host, runs the restore through SSM and waits for it; it
    # always succeeds and reports the outcome in its output.
    RunRestore = {
      Type     = "Task"
      Resource = "arn:aws:states:::states:startExecution.sync:2"
      Parameters = {
        StateMachineArn = aws_sfn_state_machine.db_backup_restore.arn
        Input = {
          restore = {
            region        = var.dr_region
            instance_name = var.db_instance_name
          }
        }
      }
      TimeoutSeconds = local.db_backup_restore_timeout_seconds + 300
      ResultSelector = local.db_backup_restore_result_selector
      ResultPath     = "$.restore"
      Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.restoreError", Next = "MarkRestoreFailed" }]
      Next           = "EvaluateRestore"
    }

    EvaluateRestore = {
      Type = "Choice"
      Choices = [
        { Variable = "$.restore.status", StringEquals = "Success", Next = "MarkRestored" },
        { Variable = "$.restore.status", StringEquals = "NoHost", Next = "MarkNoDbHost" },
      ]
      Default = "MarkRestoreFailed"
    }

    NoDbHost = {
      Type  = "Fail"
      Error = "DbHostNotFound"
      Cause = "The deploy finished but there is no running database host to restore into."
    }

    Restored = { Type = "Succeed" }

    RestoreFailed = {
      Type  = "Fail"
      Error = "RestoreFailed"
      Cause = "The database could not be restored from the latest dump; see the output of the db_backup_restore execution or the logs of the restore_db lambda."
    }

    # The DR region now serves: start watching for the primary to come back. If this breaks the
    # execution fails: a successful execution means everything is in place, and only then should the
    # traffic be switched.
    EnableRecoveryCheck = {
      Type       = "Task"
      Resource   = "arn:aws:states:::aws-sdk:eventbridge:enableRule"
      Parameters = { Name = module.auth_service_primary_recovery_check.schedule_rule_name }
      ResultPath = null
      Retry = [{
        ErrorEquals     = ["States.ALL"]
        IntervalSeconds = 2
        MaxAttempts     = 3
        BackoffRate     = 2
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "RecoveryCheckNotEnabled" }]
      Next  = "Restored"
    }

    StateRecordFailed = {
      Type  = "Fail"
      Error = "FailoverStateUpdateFailed"
      Cause = "The DR region is up and restored, but the failover state could not be recorded as DR_ACTIVE. Do not switch the traffic until the state table is checked and fixed."
    }

    RecoveryCheckNotEnabled = {
      Type  = "Fail"
      Error = "RecoveryCheckNotEnabled"
      Cause = "The DR region is up and restored and the state is DR_ACTIVE, but the schedule of primary_recovery_check could not be enabled. Enable it by hand, then switch the traffic."
    }
  }
}

resource "aws_sfn_state_machine" "failover" {
  name     = "${var.name_prefix}-auth_service-failover"
  role_arn = aws_iam_role.failover_sfn.arn

  # Step Functions checks the permissions of the role (e.g. the managed rules of the .sync
  # integrations) when it saves the definition, so the policy must be in place before.
  depends_on = [aws_iam_role_policy.failover_sfn]

  definition = jsonencode({
    Comment        = "Confirms the backend is really down and the primary region is impaired, brings up the auth service in the DR region and restores the latest dump."
    StartAt        = "CheckFailoverState"
    TimeoutSeconds = 10800
    States = merge(local.failover_states, {
      # Cheap early exit when the DR region already serves, so a repeated alarm neither re-runs the
      # checks nor sends a misleading "local outage" email. The real lock is AcquireFailoverLock; a
      # failed read here just continues.
      CheckFailoverState = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:getItem"
        Parameters = {
          TableName      = aws_dynamodb_table.failover_state.name
          Key            = local.failover_state_key
          ConsistentRead = true
        }
        ResultSelector = { "status.$" = "$.Item.status.S" }
        ResultPath     = "$.state"
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "InitChecks" }]
        Next           = "EvaluateFailoverState"
      }

      EvaluateFailoverState = {
        Type    = "Choice"
        Choices = [{ Variable = "$.state.status", StringEquals = "DR_ACTIVE", Next = "FailoverAlreadyActive" }]
        Default = "InitChecks"
      }

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
        Default = "CheckRegion"
      }

      # The backend is confirmed down. Failing over to another region only makes sense if the primary
      # region itself is impaired; a single host or AZ is handled where the service runs (Multi-AZ).
      CheckRegion = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.auth_service_region_check.function_arn
          Payload      = {}
        }
        ResultSelector = {
          "down.$"   = "$.Payload.region_down"
          "failed.$" = "$.Payload.failed"
          "total.$"  = "$.Payload.total"
        }
        ResultPath = "$.region"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 2
          MaxAttempts     = 2
        }]
        # Like the health check: a broken checker is not proof of a regional outage.
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "RegionCheckFailed" }]
        Next  = "EvaluateRegion"
      }

      EvaluateRegion = {
        Type    = "Choice"
        Choices = [{ Variable = "$.region.down", BooleanEquals = true, Next = "AcquireFailoverLock" }]
        Default = "NotifyLocalOutage"
      }

      # Records that a failover is running. The condition makes it a lock: if the DR region already
      # serves (or another execution is failing over) nothing else is started.
      AcquireFailoverLock = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = aws_dynamodb_table.failover_state.name
          Key                      = local.failover_state_key
          UpdateExpression         = "SET #s = :new, updated_at = :now, execution_arn = :exec"
          ConditionExpression      = "#s IN (:primary, :failed)"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":new"     = { S = "FAILING_OVER" }
            ":primary" = { S = "PRIMARY" }
            ":failed"  = { S = "FAILOVER_FAILED" }
            ":now"     = { "S.$" = "$$.State.EnteredTime" }
            ":exec"    = { "S.$" = "$$.Execution.Id" }
          }
        }
        ResultPath = null
        Catch = [
          { ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"], ResultPath = null, Next = "ReadFailoverState" },
          { ErrorEquals = ["States.ALL"], ResultPath = "$.lockError", Next = "FailoverStateError" },
        ]
        Next = "StartFailoverBuild"
      }

      # The lock is taken. If it is a failover in progress, check that its execution is really alive: an
      # execution that timed out or was aborted never reached the final states and would hold the lock forever.
      ReadFailoverState = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:getItem"
        Parameters = {
          TableName      = aws_dynamodb_table.failover_state.name
          Key            = local.failover_state_key
          ConsistentRead = true
        }
        ResultSelector = { "status.$" = "$.Item.status.S", "execution_arn.$" = "$.Item.execution_arn.S" }
        ResultPath     = "$.lock"
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.lockError", Next = "FailoverStateError" }]
        Next           = "EvaluateLock"
      }

      EvaluateLock = {
        Type    = "Choice"
        Choices = [{ Variable = "$.lock.status", StringEquals = "FAILING_OVER", Next = "DescribeLockOwner" }]
        Default = "FailoverAlreadyActive"
      }

      DescribeLockOwner = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sfn:describeExecution"
        Parameters = {
          "ExecutionArn.$" = "$.lock.execution_arn"
        }
        ResultSelector = { "status.$" = "$.Status" }
        ResultPath     = "$.owner"
        Catch = [
          # Too old to be described: certainly not running.
          { ErrorEquals = ["Sfn.ExecutionDoesNotExistException"], ResultPath = null, Next = "TakeOverLock" },
          # Cannot prove it is dead: leave the lock alone.
          { ErrorEquals = ["States.ALL"], ResultPath = null, Next = "FailoverAlreadyActive" },
        ]
        Next = "EvaluateLockOwner"
      }

      EvaluateLockOwner = {
        Type    = "Choice"
        Choices = [{ Variable = "$.owner.status", StringEquals = "RUNNING", Next = "FailoverAlreadyActive" }]
        Default = "TakeOverLock"
      }

      # Compare-and-swap on the dead execution's ARN, so two new executions cannot both take it over.
      TakeOverLock = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = aws_dynamodb_table.failover_state.name
          Key                      = local.failover_state_key
          UpdateExpression         = "SET updated_at = :now, execution_arn = :exec"
          ConditionExpression      = "#s = :failing AND execution_arn = :old"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":failing" = { S = "FAILING_OVER" }
            ":old"     = { "S.$" = "$.lock.execution_arn" }
            ":now"     = { "S.$" = "$$.State.EnteredTime" }
            ":exec"    = { "S.$" = "$$.Execution.Id" }
          }
        }
        ResultPath = null
        Catch = [
          { ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"], ResultPath = null, Next = "FailoverAlreadyActive" },
          { ErrorEquals = ["States.ALL"], ResultPath = "$.lockError", Next = "FailoverStateError" },
        ]
        Next = "StartFailoverBuild"
      }

      FailoverAlreadyActive = {
        Type    = "Succeed"
        Comment = "A failover is already running or the DR region already serves: nothing to do."
      }

      FailoverStateError = {
        Type  = "Fail"
        Error = "FailoverStateUnavailable"
        Cause = "The failover state table could not be updated, so no failover was started."
      }

      NotifyLocalOutage = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.alerts.arn
          Subject  = "Backend down, primary region OK: no failover"
          "Message.$" = join("", [
            "States.Format('The backend health check keeps failing but the primary region answers (",
            "{} of {} probes failed). Treated as a local outage: the DR failover was NOT started. ",
            "Check the backend host and its Availability Zone; start the failover by hand if the region is really affected.', ",
            "$.region.failed, $.region.total)",
          ])
        }
        ResultPath = null
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "LocalOutage" }]
        Next       = "LocalOutage"
      }

      LocalOutage = {
        Type    = "Succeed"
        Comment = "The backend is down but the primary region is not: no failover."
      }

      RegionCheckFailed = {
        Type  = "Fail"
        Error = "RegionCheckFailed"
        Cause = "The region check lambda failed, so a regional outage could not be confirmed. No failover was started."
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
    }, local.failover_status_updates)
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
