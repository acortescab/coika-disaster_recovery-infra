# aws-disaster-recovery

Code and automation for AWS disaster recovery. Each lambda is packaged as a container image, validated in CI (ruff + pytest) and pushed to ECR when merged to `main`.

## Structure

```
lambdas/<service>/<lambda>/    # one folder per lambda (app.py, Dockerfile, requirements*.txt, tests/)
infra/                         # infrastructure as code (Terraform/SAM/CDK): lambdas, alarms, ECR, IAM
docs/runbooks/                 # step-by-step recovery procedures
scripts/                       # operational utilities (failover, restores, ...)
.github/
  workflows/ci.yml             # single workflow: detects changed lambdas and runs a matrix
  workflows/lambda-ci.yml      # reusable: lint, test, build and push to ECR for ONE lambda
  scripts/changed_lambdas.py   # computes the matrix of affected lambdas
ruff.toml                      # shared lint config
```

Current lambdas:

| Lambda | Description |
| --- | --- |
| `auth_service/health_check` | Sends a GET to `HEALTH_URL` and publishes the `BackendHealth` metric to CloudWatch (`Coika.DisasterRecovery`). |

## Adding a new lambda

1. Create `lambdas/<service>/<name>/` with `app.py`, `Dockerfile`, `requirements.txt`, `requirements-dev.txt` and `tests/` (copy an existing one).
2. Create the ECR repository `<ECR_REPOSITORY_PREFIX>/<service>/<name>`.

No YAML needs to be touched: `ci.yml` discovers any `lambdas/*/*/` folder that has a `Dockerfile`.

## Local development

```powershell
cd lambdas/<service>/<name>
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
ruff check .
pytest
```

## CI

- Only lambdas with changes are processed. If something shared changes (`ruff.toml`, `.github/workflows/ci.yml`, `lambda-ci.yml` or `.github/scripts/`), all of them are processed.
- On PRs: lint + tests + image build (no push).
- On push to `main`: also ECR login and push with `<sha>` and `latest` tags.
- Each lambda runs in parallel and a failure does not cancel the others.
- It can also be triggered manually (`workflow_dispatch`) to process all lambdas.

## GitHub configuration (Settings > Secrets and variables > Actions)

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `AWS_ROLE_ARN` | IAM role assumed by the workflow via OIDC |
| Variable | `AWS_REGION` | AWS / ECR region |
| Variable | `ECR_REPOSITORY_PREFIX` | Prefix of the ECR repositories, e.g. `dr` |

The IAM role needs an OIDC trust policy for GitHub (`token.actions.githubusercontent.com`) restricted to this repository and the `main` branch, plus push permissions on the ECR repositories.

## License

[MIT](LICENSE) (c) 2026 Alejandro Cortés Cabrejas.

## Lambda environment variables

- `auth_service/health_check`: `HEALTH_URL` (required), URL of the backend health endpoint.
