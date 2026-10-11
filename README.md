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
| `auth_service/health_check` | Sends a GET to `HEALTH_URL` and publishes the `BackendHealth` metric to CloudWatch (`Coika/DisasterRecovery`). |

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

## Region strategy

The goal is to survive the loss of an entire AWS region. Therefore **everything in this repo is deployed in the DR region, not in the primary one** (where the services run):

- Detection (`health_check`) runs in the DR region and probes the primary backend over the internet. If the primary region goes down, the check fails and the alarm still works.
- ECR repositories and images, the orchestration (Step Functions, CodeBuild) and the Terraform state live in the DR region, so recovery can start while the primary region is unavailable.
- Each service keeps its own infrastructure code in its own repo; the DR orchestration applies it in the DR region.

Single-AZ failures are not handled here: they are absorbed by the services themselves (Multi-AZ).

## Infrastructure (Terraform)

`infra/` creates, per lambda: the ECR repository (with a lifecycle policy), the execution role, the log group, the function (container image) and an optional EventBridge schedule. Each lambda is one `module` call in `infra/main.tf`.

First deployment (the function needs an image in ECR before it can be created):

```powershell
cd infra
copy terraform.tfvars.example terraform.tfvars   # edit the values
terraform init
terraform apply -target=module.auth_service_health_check.aws_ecr_repository.this
# push an image once (merge to main, or docker build/push by hand with the `latest` tag)
terraform apply
```

After that, every merge to `main` builds and pushes the image and CI runs `aws lambda update-function-code`, so Terraform only manages infrastructure (it ignores `image_uri` changes). Function and repository names come from `<prefix>-<service>-<name>` and `<prefix>/<service>/<name>`, and must stay in sync with `changed_lambdas.py`.

## GitHub configuration (Settings > Secrets and variables > Actions)

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `AWS_ROLE_ARN` | IAM role assumed by the workflow via OIDC |
| Variable | `AWS_REGION` | **DR region** (same value as `dr_region` in Terraform), used for ECR and Lambda |
| Variable | `ECR_REPOSITORY_PREFIX` | Prefix of the ECR repositories, e.g. `coika/disaster_recovery` |
| Variable | `LAMBDA_NAME_PREFIX` | Prefix of the function names, e.g. `coika` (same as `name_prefix` in Terraform) |

The IAM role needs an OIDC trust policy for GitHub (`token.actions.githubusercontent.com`) restricted to this repository and the `main` branch, plus push permissions on the ECR repositories and `lambda:UpdateFunctionCode` / `lambda:GetFunctionConfiguration` on the functions (`arn:aws:lambda:<region>:<account-id>:function:<prefix>-*`).

## License

[MIT](LICENSE) (c) 2026 Alejandro Cortés Cabrejas.

## Lambda environment variables

- `auth_service/health_check`: `HEALTH_URL` (required), URL of the backend health endpoint.
