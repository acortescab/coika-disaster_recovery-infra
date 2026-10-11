# Alarm state changes -> EventBridge (formats a readable message) -> SNS -> email.
# EventBridge is used instead of alarm_actions because the default CloudWatch email is raw JSON.

resource "aws_sns_topic" "alerts" {
  name = "coika-disaster_recovery-topic"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "backend_alarm" {
  name        = "${var.name_prefix}-backend-alarm-state"
  description = "Notify when the backend alarm changes between ALARM and OK."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.backend_unhealthy.alarm_name]
      state     = { value = ["ALARM", "OK"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "backend_alarm_email" {
  rule = aws_cloudwatch_event_rule.backend_alarm.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      alarm  = "$.detail.alarmName"
      state  = "$.detail.state.value"
      before = "$.detail.previousState.value"
      reason = "$.detail.state.reason"
      time   = "$.time"
      region = "$.region"
    }

    input_template = "\"Alarm <alarm>: <state> (previous: <before>)\\n\\nFastAPI backend: BackendHealth < 1 means the health check is failing; when it returns to OK, the backend has recovered.\\n\\nReason: <reason>\\nTime (UTC): <time>\\nRegion: <region>\\n\\nIf the state is ALARM, check the backend in the primary region and consider starting the failover to the DR region.\""
  }
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.backend_alarm.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
