# Which region serves the auth service right now. It lives in the DR region (never in the primary one,
# which may be down) and is written by the failover state machine. Besides recording the switch, it is a
# lock: the failover only starts if the status allows it, so a repeated alarm or a second execution
# cannot start a second failover.
#
#   PRIMARY          -> the primary region serves (normal state)
#   FAILING_OVER     -> a failover execution is running
#   DR_ACTIVE        -> the DR region serves
#   FAILOVER_FAILED  -> the last failover did not finish; a new one may start
#   (FAILING_BACK    -> reserved for the failback state machine)

resource "aws_dynamodb_table" "failover_state" {
  name         = "${var.name_prefix}-auth_service-failover-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service"

  attribute {
    name = "service"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Initial state. After creation the state machine owns the item, so Terraform must not reset it.
resource "aws_dynamodb_table_item" "failover_state" {
  table_name = aws_dynamodb_table.failover_state.name
  hash_key   = aws_dynamodb_table.failover_state.hash_key

  item = jsonencode({
    service = { S = "auth_service" }
    status  = { S = "PRIMARY" }
  })

  lifecycle {
    ignore_changes = [item]
  }
}

locals {
  failover_state_key = { service = { S = "auth_service" } }

  # With `plan` nothing is brought up, so a "successful" failover leaves the primary as the active region.
  failover_success_status = var.failover_tf_action == "apply" ? "DR_ACTIVE" : "PRIMARY"

  # Final failover states: record the outcome, then continue to the terminal state. A failed update
  # must not hide the real result, so every error moves on to the same next state.
  failover_status_updates = {
    for name, s in {
      MarkRestored      = { status = local.failover_success_status, next = "Restored" }
      MarkNoDbHost      = { status = var.failover_tf_action == "apply" ? "FAILOVER_FAILED" : "PRIMARY", next = "NoDbHost" }
      MarkBuildFailed   = { status = "FAILOVER_FAILED", next = "BuildFailed" }
      MarkRestoreFailed = { status = "FAILOVER_FAILED", next = "RestoreFailed" }
      } : name => {
      Type     = "Task"
      Resource = "arn:aws:states:::dynamodb:updateItem"
      Parameters = {
        TableName                = aws_dynamodb_table.failover_state.name
        Key                      = local.failover_state_key
        UpdateExpression         = "SET #s = :new, updated_at = :now, execution_arn = :exec"
        ExpressionAttributeNames = { "#s" = "status" }
        ExpressionAttributeValues = {
          ":new"  = { S = s.status }
          ":now"  = { "S.$" = "$$.State.EnteredTime" }
          ":exec" = { "S.$" = "$$.Execution.Id" }
        }
      }
      ResultPath = null
      Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = null, Next = s.next }]
      Next       = s.next
    }
  }
}
