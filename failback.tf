# Failback: moves the auth service from the DR region back to the primary region once the primary is
# healthy again. It is started by hand (there is no trigger yet; `primary_recovery_check` only
# notifies that the primary looks recovered):
#
#   aws stepfunctions start-execution --state-machine-arn <failback_state_machine_arn>
#
# The primary stack is assumed to be still deployed (it was only unreachable), so nothing is built
# there: the DB of the primary host is overwritten with a fresh dump of the DR database. Two steps
# need a person and wait for a task token that the notification carries:
#   1. stop the writes in DR (so the dump is complete),
#   2. switch the traffic (DNS) to the primary once its database is restored.
# Any failure or cancellation before the traffic switch aborts the failback: the state goes back to
# DR_ACTIVE and the DR region keeps serving. After the switch the state is PRIMARY and the DR stack
# is destroyed (failback_teardown_dr) or left for the `-down` build to be started by hand.
#
# A failback execution that dies without reaching its final states (timeout, aborted by hand) leaves
# the state at FAILING_BACK. Reset it by hand once you know which region serves:
#   aws dynamodb update-item --table-name <failover_state_table> --key '{"service":{"S":"auth_service"}}' \
#     --update-expression 'SET #s = :s' --expression-attribute-names '{"#s":"status"}' \
#     --expression-attribute-values '{":s":{"S":"DR_ACTIVE"}}'

resource "aws_cloudwatch_log_group" "failback_sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-auth_service-failback"
  retention_in_days = 30
}

resource "aws_iam_role" "failback_sfn" {
  name               = "${var.name_prefix}-auth_service-failback-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "failback_sfn" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      module.auth_service_region_check.function_arn,
      module.auth_service_backup_db.function_arn,
      module.auth_service_restore_db.function_arn,
    ]
  }

  statement {
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.failover_state.arn]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    actions   = ["events:EnableRule", "events:DisableRule"]
    resources = [module.auth_service_primary_recovery_check.schedule_rule_arn]
  }

  statement {
    actions   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.failover["down"].arn]
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

resource "aws_iam_role_policy" "failback_sfn" {
  name   = "failback"
  role   = aws_iam_role.failback_sfn.id
  policy = data.aws_iam_policy_document.failback_sfn.json
}

locals {
  # Final status of the failback, written unconditionally: both clear the fields of the recovery check
  # so the next cycle starts clean.
  failback_status_params = {
    for status in ["PRIMARY", "DR_ACTIVE"] : status => {
      TableName                = aws_dynamodb_table.failover_state.name
      Key                      = local.failover_state_key
      UpdateExpression         = "SET #s = :new, updated_at = :now, execution_arn = :exec REMOVE recovery_streak, recovery_notified_at"
      ExpressionAttributeNames = { "#s" = "status" }
      ExpressionAttributeValues = {
        ":new"  = { S = status }
        ":now"  = { "S.$" = "$$.State.EnteredTime" }
        ":exec" = { "S.$" = "$$.Execution.Id" }
      }
    }
  }

  failback_states = {
    # Only a failback from DR_ACTIVE is allowed; it also keeps a second failback (or a failover)
    # from starting while this one runs.
    AcquireFailbackLock = {
      Type     = "Task"
      Resource = "arn:aws:states:::dynamodb:updateItem"
      Parameters = {
        TableName                = aws_dynamodb_table.failover_state.name
        Key                      = local.failover_state_key
        UpdateExpression         = "SET #s = :new, updated_at = :now, execution_arn = :exec"
        ConditionExpression      = "#s = :dr"
        ExpressionAttributeNames = { "#s" = "status" }
        ExpressionAttributeValues = {
          ":new"  = { S = "FAILING_BACK" }
          ":dr"   = { S = "DR_ACTIVE" }
          ":now"  = { "S.$" = "$$.State.EnteredTime" }
          ":exec" = { "S.$" = "$$.Execution.Id" }
        }
      }
      ResultPath = null
      Catch = [
        { ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"], ResultPath = null, Next = "FailbackNotAllowed" },
        { ErrorEquals = ["States.ALL"], ResultPath = null, Next = "FailbackStateError" },
      ]
      Next = "DisableRecoveryCheck"
    }

    FailbackNotAllowed = {
      Type  = "Fail"
      Error = "FailbackNotAllowed"
      Cause = "The DR region is not serving (the failover state is not DR_ACTIVE), so there is nothing to fail back."
    }

    FailbackStateError = {
      Type  = "Fail"
      Error = "FailoverStateUnavailable"
      Cause = "The failover state table could not be updated; check its state before starting another failback."
    }

    # The recovery check has done its job. Best effort.
    DisableRecoveryCheck = {
      Type       = "Task"
      Resource   = "arn:aws:states:::aws-sdk:eventbridge:disableRule"
      Parameters = { Name = module.auth_service_primary_recovery_check.schedule_rule_name }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "CheckPrimaryRegion" }]
      Next       = "CheckPrimaryRegion"
    }

    # Same probes as the outage check, as a last look before anything is changed.
    CheckPrimaryRegion = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke"
      Parameters = {
        FunctionName = module.auth_service_region_check.function_arn
        Payload      = {}
      }
      ResultSelector = { "down.$" = "$.Payload.region_down" }
      ResultPath     = "$.region"
      Retry = [{
        ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
        IntervalSeconds = 2
        MaxAttempts     = 2
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "AbortFailback" }]
      Next  = "EvaluatePrimaryRegion"
    }

    EvaluatePrimaryRegion = {
      Type    = "Choice"
      Choices = [{ Variable = "$.region.down", BooleanEquals = true, Next = "AbortFailback" }]
      Default = "AskStopWrites"
    }

    # Manual step 1. The dump must be taken with nothing writing to the DR database, otherwise the
    # writes made after it are lost when the traffic moves.
    AskStopWrites = {
      Type     = "Task"
      Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
      Parameters = {
        TopicArn = aws_sns_topic.alerts.arn
        Subject  = "Failback: stop the writes in the DR region"
        # No line breaks or braces in the template: `{}` is the placeholder of States.Format.
        "Message.$" = join("", [
          "States.Format('The primary region answers again and the failback is ready to start. ",
          "Put the DR service in maintenance (stop the API) so nothing writes to the DR database, then confirm with: ",
          "aws stepfunctions send-task-success --task-token {} --task-output 1 ",
          "-- To cancel (the DR region keeps serving): ",
          "aws stepfunctions send-task-failure --task-token {} --error Cancelled', ",
          "$$.Task.Token, $$.Task.Token)",
        ])
      }
      TimeoutSeconds = var.failback_approval_timeout_seconds
      ResultPath     = null
      Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "AbortFailback" }]
      Next           = "BackupDr"
    }

    # Dump of the DR database. The snapshots bucket replicates it to the primary region.
    BackupDr = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke"
      Parameters = {
        FunctionName = module.auth_service_backup_db.function_arn
        "Payload.$"  = "$.backup"
      }
      TimeoutSeconds = 930
      ResultSelector = {
        "status.$"      = "$.Payload.status"
        "message.$"     = "$.Payload.message"
        "key.$"         = "$.Payload.key"
        "instance_id.$" = "$.Payload.instance_id"
        "command_id.$"  = "$.Payload.command_id"
        "started_at.$"  = "$.Payload.started_at"
      }
      ResultPath = "$.backup"
      Retry = [{
        ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
        IntervalSeconds = 2
        MaxAttempts     = 3
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "AbortFailback" }]
      Next  = "EvaluateBackup"
    }

    EvaluateBackup = {
      Type = "Choice"
      Choices = [
        { Variable = "$.backup.status", StringEquals = "Success", Next = "StartRestorePrimary" },
        { Variable = "$.backup.status", StringEquals = "InProgress", Next = "BackupDr" },
      ]
      Default = "AbortFailback"
    }

    StartRestorePrimary = {
      Type = "Pass"
      Parameters = {
        "region"    = var.primary_region
        "key.$"     = "$.backup.key"
        "overwrite" = true
      }
      ResultPath = "$.restore"
      Next       = "RestorePrimary"
    }

    # Same lambda as the failover, pointed at the primary host: it waits until the dump has been
    # replicated to the primary bucket and restores it over the old data.
    RestorePrimary = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke"
      Parameters = {
        FunctionName = module.auth_service_restore_db.function_arn
        "Payload.$"  = "$.restore"
      }
      TimeoutSeconds = 930
      ResultSelector = {
        "status.$"      = "$.Payload.status"
        "message.$"     = "$.Payload.message"
        "instance_id.$" = "$.Payload.instance_id"
        "command_id.$"  = "$.Payload.command_id"
        "started_at.$"  = "$.Payload.started_at"
        "region.$"      = "$.Payload.region"
        "key.$"         = "$.Payload.key"
        "overwrite.$"   = "$.Payload.overwrite"
      }
      ResultPath = "$.restore"
      Retry = [{
        ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
        IntervalSeconds = 2
        MaxAttempts     = 3
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "AbortFailback" }]
      Next  = "EvaluateRestore"
    }

    EvaluateRestore = {
      Type = "Choice"
      Choices = [
        { Variable = "$.restore.status", StringEquals = "Success", Next = "AskSwitchTraffic" },
        { Variable = "$.restore.status", StringEquals = "InProgress", Next = "RestorePrimary" },
      ]
      Default = "AbortFailback"
    }

    # Manual step 2. Up to here the DR region is still the source of truth, so cancelling is safe.
    AskSwitchTraffic = {
      Type     = "Task"
      Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
      Parameters = {
        TopicArn = aws_sns_topic.alerts.arn
        Subject  = "Failback: switch the traffic to the primary region"
        "Message.$" = join("", [
          "States.Format('The primary database was restored from {}. ",
          "Start the API in the primary region, switch the DNS to it and check it, then confirm with: ",
          "aws stepfunctions send-task-success --task-token {} --task-output 1 ",
          "-- To cancel (the DR region keeps serving; restart its API): ",
          "aws stepfunctions send-task-failure --task-token {} --error Cancelled', ",
          "$.backup.key, $$.Task.Token, $$.Task.Token)",
        ])
      }
      TimeoutSeconds = var.failback_approval_timeout_seconds
      ResultPath     = null
      Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "AbortFailback" }]
      Next           = "MarkPrimary"
    }

    # The traffic is on the primary: from here the failback is no longer reversible by this execution.
    MarkPrimary = {
      Type       = "Task"
      Resource   = "arn:aws:states:::dynamodb:updateItem"
      Parameters = local.failback_status_params["PRIMARY"]
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "FailbackStateError" }]
      Next       = var.failback_teardown_dr ? "TearDownDr" : "NotifyManualTeardown"
    }

    TearDownDr = {
      Type     = "Task"
      Resource = "arn:aws:states:::codebuild:startBuild.sync"
      Parameters = {
        ProjectName = aws_codebuild_project.failover["down"].name
      }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "NotifyTeardownFailed" }]
      Next       = "FailbackDone"
    }

    NotifyTeardownFailed = {
      Type     = "Task"
      Resource = "arn:aws:states:::sns:publish"
      Parameters = {
        TopicArn = aws_sns_topic.alerts.arn
        Subject  = "Failback done, but the DR teardown failed"
        Message  = "The auth service is back on the primary region, but the -down build failed. The DR stack is still running (and costing money): check the build logs and start the -down build again."
      }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "TeardownFailed" }]
      Next       = "TeardownFailed"
    }

    TeardownFailed = {
      Type  = "Fail"
      Error = "DrTeardownFailed"
      Cause = "The failback finished (the state is PRIMARY) but the -down build failed; the DR stack is still running."
    }

    NotifyManualTeardown = {
      Type     = "Task"
      Resource = "arn:aws:states:::sns:publish"
      Parameters = {
        TopicArn = aws_sns_topic.alerts.arn
        Subject  = "Failback done: the DR stack is still running"
        Message  = "The auth service is back on the primary region. The DR stack was left running: start the -down build when you are sure the primary is stable."
      }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "FailbackDone" }]
      Next       = "FailbackDone"
    }

    FailbackDone = {
      Type    = "Succeed"
      Comment = "The primary region serves again."
    }

    # Any failure before the traffic moved: the DR region stays the source of truth.
    AbortFailback = {
      Type       = "Task"
      Resource   = "arn:aws:states:::dynamodb:updateItem"
      Parameters = local.failback_status_params["DR_ACTIVE"]
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "EnableRecoveryCheck" }]
      Next       = "EnableRecoveryCheck"
    }

    # The DR region serves again, so keep watching for the primary. Best effort.
    EnableRecoveryCheck = {
      Type       = "Task"
      Resource   = "arn:aws:states:::aws-sdk:eventbridge:enableRule"
      Parameters = { Name = module.auth_service_primary_recovery_check.schedule_rule_name }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "NotifyAborted" }]
      Next       = "NotifyAborted"
    }

    NotifyAborted = {
      Type     = "Task"
      Resource = "arn:aws:states:::sns:publish"
      Parameters = {
        TopicArn = aws_sns_topic.alerts.arn
        Subject  = "Failback aborted: the DR region keeps serving"
        Message  = "The failback was cancelled or failed before the traffic moved, so the DR region is still the source of truth (state DR_ACTIVE). If you stopped the API in DR for the dump, start it again. See the execution history for the reason."
      }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = "FailbackAborted" }]
      Next       = "FailbackAborted"
    }

    FailbackAborted = {
      Type  = "Fail"
      Error = "FailbackAborted"
      Cause = "The failback was cancelled or failed before the traffic moved; the state is DR_ACTIVE again."
    }
  }
}

resource "aws_sfn_state_machine" "failback" {
  name     = "${var.name_prefix}-auth_service-failback"
  role_arn = aws_iam_role.failback_sfn.arn

  definition = jsonencode({
    Comment        = "Dumps the DR database, restores it in the primary region and, after two manual confirmations, marks the primary as the active region again."
    StartAt        = "StartBackup"
    TimeoutSeconds = 3 * var.failback_approval_timeout_seconds
    States = merge(local.failback_states, {
      # Lock first: nothing is changed if the DR region is not the one serving.
      StartBackup = {
        Type       = "Pass"
        Result     = {}
        ResultPath = "$.backup"
        Next       = "AcquireFailbackLock"
      }
    })
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = false
    log_destination        = "${aws_cloudwatch_log_group.failback_sfn.arn}:*"
  }
}
