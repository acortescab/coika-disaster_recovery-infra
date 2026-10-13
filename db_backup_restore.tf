# Reusable state machine: optionally dumps a database and restores it on another DB host. It knows
# nothing about the auth service or about failover; the callers (the failover and the failback state
# machines, or anything else, even by hand) pass which hosts to use. It is the only place that
# orchestrates the backup_db and restore_db lambdas.
#
# Input (the restore is always required, the backup is optional):
#
#   {
#     "backup":  { "region": "eu-central-1", "instance_name": "my-db-host" },
#     "restore": { "region": "eu-west-1",    "instance_name": "my-db-host" }
#   }
#
#   backup    present: dumps the DB of that host to the snapshots bucket of its region and restores THAT
#             dump (the bucket replicates it to the other region, the restore waits for it).
#             absent: nothing is dumped and the restore takes the newest dump of the bucket.
#   restore   host to restore into. DESTRUCTIVE: the restore replaces the data of its database. It does
#             not check whether that data is worth keeping; the caller must not run this state machine
#             against a database that is serving good data.
#
# It never fails because of the outcome: the execution always succeeds and the output says what
# happened, so the caller decides what to do (a caller only sees a failed execution if this state
# machine itself breaks):
#
#   { "status": "Success" | "NoHost" | "Failed", "phase": "backup" | "restore",
#     "message": "...", "key": "<dump restored, or null>" }

locals {
  # Backup (at most MAX_WAIT_SECONDS of backup_db, 1800) plus restore (2700 of restore_db), and margin.
  db_backup_restore_timeout_seconds = 6000

  db_backup_restore_executions_arn = "arn:aws:states:${var.dr_region}:${local.account_id}:execution:${var.name_prefix}-db_backup_restore:*"

  # How the callers read the output of the nested execution (startExecution.sync:2).
  db_backup_restore_result_selector = {
    "status.$"  = "$.Output.status"
    "phase.$"   = "$.Output.phase"
    "message.$" = "$.Output.message"
    "key.$"     = "$.Output.key"
  }

  # Payload of a lambda call that is repeated while the lambda answers InProgress (a lambda lives at most
  # 15 minutes): it carries the ids needed to resume the command, see the lambdas.
  db_backup_restore_lambda_result = {
    "status.$"        = "$.Payload.status"
    "message.$"       = "$.Payload.message"
    "key.$"           = "$.Payload.key"
    "instance_id.$"   = "$.Payload.instance_id"
    "command_id.$"    = "$.Payload.command_id"
    "started_at.$"    = "$.Payload.started_at"
    "region.$"        = "$.Payload.region"
    "instance_name.$" = "$.Payload.instance_name"
  }

  db_backup_restore_lambda_retry = [{
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
    IntervalSeconds = 2
    MaxAttempts     = 3
  }]

  # Final states: a Pass that shapes the output.
  db_backup_restore_outcomes = {
    for name, o in {
      BackupNoHost  = { status = "NoHost", phase = "backup", message = "$.backupRun.message" }
      BackupFailed  = { status = "Failed", phase = "backup", message = "$.backupRun.message" }
      BackupError   = { status = "Failed", phase = "backup", message = "$.error.Cause" }
      RestoreNoHost = { status = "NoHost", phase = "restore", message = "$.restoreRun.message" }
      RestoreFailed = { status = "Failed", phase = "restore", message = "$.restoreRun.message" }
      RestoreError  = { status = "Failed", phase = "restore", message = "$.error.Cause" }
      } : name => {
      Type = "Pass"
      Parameters = {
        status      = o.status
        phase       = o.phase
        "message.$" = o.message
        key         = null
      }
      End = true
    }
  }
}

resource "aws_cloudwatch_log_group" "db_backup_restore_sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-db_backup_restore"
  retention_in_days = 30
}

resource "aws_iam_role" "db_backup_restore_sfn" {
  name                 = "${var.name_prefix}-db_backup_restore-sfn-role"
  assume_role_policy   = data.aws_iam_policy_document.sfn_assume.json
  permissions_boundary = aws_iam_policy.pipeline_boundary.arn
}

data "aws_iam_policy_document" "db_backup_restore_sfn" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      module.auth_service_backup_db.function_arn,
      module.auth_service_restore_db.function_arn,
    ]
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

resource "aws_iam_role_policy" "db_backup_restore_sfn" {
  name   = "db-backup-restore"
  role   = aws_iam_role.db_backup_restore_sfn.id
  policy = data.aws_iam_policy_document.db_backup_restore_sfn.json
}

resource "aws_sfn_state_machine" "db_backup_restore" {
  name     = "${var.name_prefix}-db_backup_restore"
  role_arn = aws_iam_role.db_backup_restore_sfn.arn

  # Step Functions checks the permissions of the role when it saves the definition.
  depends_on = [aws_iam_role_policy.db_backup_restore_sfn]

  definition = jsonencode({
    Comment        = "Optionally dumps a database and restores it on another DB host; reusable for any database. See db_backup_restore.tf."
    StartAt        = "HasBackup"
    TimeoutSeconds = local.db_backup_restore_timeout_seconds
    States = merge(local.db_backup_restore_outcomes, {
      HasBackup = {
        Type    = "Choice"
        Choices = [{ Variable = "$.backup", IsPresent = true, Next = "StartBackup" }]
        Default = "StartRestoreNewest"
      }

      # The input of the backup lambda is `backup` itself; its result replaces it at every call.
      StartBackup = {
        Type       = "Pass"
        InputPath  = "$.backup"
        ResultPath = "$.backupRun"
        Next       = "BackupDb"
      }

      # The lambda finds the host, runs backup.sh on it through SSM and waits. While it is still running
      # it answers InProgress with the ids to resume with, and EvaluateBackup calls it again.
      BackupDb = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.auth_service_backup_db.function_arn
          "Payload.$"  = "$.backupRun"
        }
        TimeoutSeconds = 930
        ResultSelector = local.db_backup_restore_lambda_result
        ResultPath     = "$.backupRun"
        Retry          = local.db_backup_restore_lambda_retry
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "BackupError" }]
        Next           = "EvaluateBackup"
      }

      EvaluateBackup = {
        Type = "Choice"
        Choices = [
          { Variable = "$.backupRun.status", StringEquals = "Success", Next = "StartRestoreBackedUp" },
          { Variable = "$.backupRun.status", StringEquals = "InProgress", Next = "BackupDb" },
          { Variable = "$.backupRun.status", StringEquals = "NoHost", Next = "BackupNoHost" },
        ]
        Default = "BackupFailed"
      }

      # Restore of the dump that was just taken.
      StartRestoreBackedUp = {
        Type = "Pass"
        Parameters = {
          "region.$"        = "$.restore.region"
          "instance_name.$" = "$.restore.instance_name"
          "key.$"           = "$.backupRun.key"
        }
        ResultPath = "$.restoreRun"
        Next       = "RestoreDb"
      }

      # Restore of the newest dump of the bucket.
      StartRestoreNewest = {
        Type = "Pass"
        Parameters = {
          "region.$"        = "$.restore.region"
          "instance_name.$" = "$.restore.instance_name"
        }
        ResultPath = "$.restoreRun"
        Next       = "RestoreDb"
      }

      RestoreDb = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.auth_service_restore_db.function_arn
          "Payload.$"  = "$.restoreRun"
        }
        TimeoutSeconds = 930
        ResultSelector = local.db_backup_restore_lambda_result
        ResultPath     = "$.restoreRun"
        Retry          = local.db_backup_restore_lambda_retry
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "RestoreError" }]
        Next           = "EvaluateRestore"
      }

      EvaluateRestore = {
        Type = "Choice"
        Choices = [
          { Variable = "$.restoreRun.status", StringEquals = "Success", Next = "Done" },
          { Variable = "$.restoreRun.status", StringEquals = "InProgress", Next = "RestoreDb" },
          { Variable = "$.restoreRun.status", StringEquals = "NoHost", Next = "RestoreNoHost" },
        ]
        Default = "RestoreFailed"
      }

      # `key` is the dump that was restored (null when the restore took the newest and was skipped or
      # did not report it).
      Done = {
        Type = "Pass"
        Parameters = {
          status      = "Success"
          phase       = "restore"
          "message.$" = "$.restoreRun.message"
          "key.$"     = "$.restoreRun.key"
        }
        End = true
      }
    })
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = false
    log_destination        = "${aws_cloudwatch_log_group.db_backup_restore_sfn.arn}:*"
  }
}
