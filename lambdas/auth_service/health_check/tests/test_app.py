import importlib.util
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, Mock

import boto3
import pytest


@pytest.fixture
def app_module(monkeypatch):
    cloudwatch = Mock()
    monkeypatch.setattr(boto3, "client", lambda service: cloudwatch)
    monkeypatch.setenv("HEALTH_URL", "https://service.test/health")

    app_path = Path(__file__).resolve().parents[1] / "app.py"
    spec = importlib.util.spec_from_file_location("health_check_app", app_path)
    app = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(app)
    return app, cloudwatch


@pytest.mark.parametrize(
    ("status_code", "expected_healthy", "metric_value"),
    [
        (200, True, 1),
        (503, False, 0),
    ],
)
def test_lambda_handler_returns_health_and_publishes_metric(
    app_module, monkeypatch, status_code, expected_healthy, metric_value
):
    app, cloudwatch = app_module
    response = MagicMock()
    response.status = status_code
    response.__enter__.return_value = response
    urlopen = Mock(return_value=response)
    monkeypatch.setattr(app.urllib.request, "urlopen", urlopen)

    result = app.lambda_handler({}, None)

    assert result == {
        "healthy": expected_healthy,
        "status_code": status_code,
        "endpoint": "https://service.test/health",
        "error": None,
    }
    request = urlopen.call_args.args[0]
    assert request.full_url == "https://service.test/health"
    assert request.get_method() == "GET"
    assert request.get_header("User-agent") == "aws-health-check"
    assert urlopen.call_args.kwargs["timeout"] == 5
    cloudwatch.put_metric_data.assert_called_once_with(
        Namespace="Coika.DisasterRecovery",
        MetricData=[
            {
                "MetricName": "BackendHealth",
                "Dimensions": [{"Name": "Service", "Value": "FastAPI"}],
                "Value": metric_value,
                "Unit": "Count",
            }
        ],
    )


def test_lambda_handler_reports_http_error_and_publishes_unhealthy_metric(
    app_module, monkeypatch
):
    app, cloudwatch = app_module
    http_error = urllib.error.HTTPError(
        "https://service.test/health", 503, "Unavailable", None, None
    )
    monkeypatch.setattr(
        app.urllib.request, "urlopen", Mock(side_effect=http_error)
    )

    result = app.lambda_handler({}, None)

    assert result == {
        "healthy": False,
        "status_code": 503,
        "endpoint": "https://service.test/health",
        "error": "HTTP error",
    }
    assert cloudwatch.put_metric_data.call_args.kwargs["MetricData"][0]["Value"] == 0


def test_lambda_handler_reports_connection_error_and_publishes_unhealthy_metric(
    app_module, monkeypatch
):
    app, cloudwatch = app_module
    monkeypatch.setattr(
        app.urllib.request,
        "urlopen",
        Mock(side_effect=TimeoutError("connection timed out")),
    )

    result = app.lambda_handler({}, None)

    assert result == {
        "healthy": False,
        "status_code": None,
        "endpoint": "https://service.test/health",
        "error": "connection timed out",
    }
    assert cloudwatch.put_metric_data.call_args.kwargs["MetricData"][0]["Value"] == 0
