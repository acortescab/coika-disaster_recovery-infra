import os
import urllib.error
import urllib.request

import boto3

cloudwatch = boto3.client("cloudwatch")

HEALTH_URL = os.environ["HEALTH_URL"]
NAMESPACE = "Coika/DisasterRecovery"
TIMEOUT_SECONDS = 5


def publish_metric(healthy: bool):
    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {
                "MetricName": "BackendHealth",
                "Dimensions": [
                    {
                        "Name": "Service",
                        "Value": "FastAPI"
                    }
                ],
                "Value": 1 if healthy else 0,
                "Unit": "Count"
            }
        ]
    )


def lambda_handler(event, context):
    status_code = None
    error = None

    try:
        request = urllib.request.Request(
            HEALTH_URL,
            method="GET",
            headers={"User-Agent": "aws-health-check"},
        )

        with urllib.request.urlopen(
            request,
            timeout=TIMEOUT_SECONDS,
        ) as response:
            status_code = response.status

        healthy = status_code == 200

    except urllib.error.HTTPError as exc:
        status_code = exc.code
        healthy = False
        error = "HTTP error"

    except (urllib.error.URLError, OSError, ValueError) as exc:
        healthy = False
        error = str(exc)

    # Publish the metric whether the check succeeds or fails.
    publish_metric(healthy)

    return {
        "healthy": healthy,
        "status_code": status_code,
        "endpoint": HEALTH_URL,
        "error": error,
    }
