resource "aws_cloudwatch_metric_alarm" "backend_unhealthy" {
  alarm_name        = "${var.name_prefix}-backend-unhealthy"
  alarm_description = "BackendHealth published by auth_service/health_check was below 1 for one minute (backend down)."

  namespace   = "Coika/DisasterRecovery"
  metric_name = "BackendHealth"
  dimensions = {
    Service = "FastAPI"
  }

  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # No datapoints means the health check is not running, which is as bad as a failing backend.
  treat_missing_data = "breaching"
}
