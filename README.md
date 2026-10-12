# coika-disaster_recovery-infra

Infrastructure as code (Terraform, at the root of the repository) of the AWS disaster recovery of the Coika services. It detects that the primary backend is down, confirms it is not a false alarm, brings the auth service up in the DR region and restores its database.

The lambdas it uses live in the sibling repository **coika-disaster_recovery** (code, tests, image build and deploy). That repo also creates their ECR repositories (`terraform/` there). This repo creates the functions (execution role, log group, environment, permissions) from the images it pushes, and wires them into the failover.

## Structure

```
main.tf                        # one `lambda_container` module call per lambda
alarms.tf, notifications.tf    # BackendHealth alarm -> EventBridge -> SNS email
stepfunctions.tf               # alarm -> EventBridge -> failover state machine
failover_state.tf              # DynamoDB table: which region serves + failover lock
failback.tf                    # failback state machine (DR -> primary), started by hand
codebuild.tf, failover/        # `-up` / `-down` builds that run the auth service stack in the DR region
service_state.tf               # DR bucket with the Terraform state of the auth service
github_oidc*.tf                # AWS roles for the GitHub workflows of this repo (plan, apply)
modules/lambda_container/      # role + log group + function (container image); looks up the ECR repository
variables.tf, versions.tf, outputs.tf, terraform.tfvars.example
docs/runbooks/                 # step-by-step recovery procedures
scripts/                       # operational utilities
.github/workflows/             # ci.yml (terraform plan on PRs), cd.yml (terraform apply on main)
```

## Failover flow

1. The `BackendHealth` alarm (fed by the `health_check` lambda) goes to `ALARM`. EventBridge emails it and starts the state machine.
2. The state machine re-runs the health check several times (`failover_validation_attempts`, every `failover_validation_interval_seconds`). Any healthy answer ends it as a false alarm.
3. It calls the `region_check` lambda, which probes the public endpoints of `region_probe_services` in `primary_region`. If fewer than `region_probe_failures_required` fail, only the backend is affected: the state machine emails a "local outage" notice and stops without failing over (a single host or AZ is handled where the service runs).
4. It starts the `-up` CodeBuild project, which runs the auth service Terraform in the DR region. With `failover_tf_action = "plan"` (default) it only shows the changes; set `"apply"` to deploy.
5. It calls the `restore_db` lambda, which restores the newest dump on the DR database host through SSM, and waits for it.

While the DR region serves, the failover state (`failover_state.tf`, DynamoDB) is `DR_ACTIVE`: it records which region serves and doubles as the lock that prevents a second failover. The `primary_recovery_check` lambda (its schedule is enabled by the failover and disabled when a failover or failback starts) counts consecutive healthy checks of the primary region and emails once when it looks recovered.

## Failback flow

Started by hand (`aws stepfunctions start-execution --state-machine-arn <failback_state_machine_arn>`); see the header of `failback.tf`. It assumes the primary stack is still deployed.

1. Takes the lock (`DR_ACTIVE` -> `FAILING_BACK`; anything else is refused), turns the recovery check off and probes the primary region once more.
2. Emails a task token and waits for you to stop the writes in DR (put the API in maintenance), so the dump is complete.
3. `backup_db` dumps the DR database; the snapshots bucket replicates it to the primary region.
4. `restore_db` (with `region`, `key` and `overwrite`) restores that dump over the database of the primary host once it has been replicated.
5. Emails a second task token and waits for you to start the API in the primary, switch the DNS and confirm.
6. Sets the state to `PRIMARY`. With `failback_teardown_dr = true` it then runs the `-down` build; by default it only notifies and `-down` (destroys the auth service in DR, keeping the ECR repository and the DB snapshots bucket) is started by hand.

Cancelling (`send-task-failure`), a failure or a timeout before step 6 aborts the failback: the state goes back to `DR_ACTIVE`, the recovery check is turned on again and the DR region keeps serving. Remember to start the DR API again if you stopped it.

## Region strategy

The goal is to survive the loss of an entire AWS region. Therefore **everything in this repo is deployed in the DR region, not in the primary one** (where the services run):

- Detection (`health_check`) runs in the DR region and probes the primary backend over the internet. If the primary region goes down, the check fails and the alarm still works.
- ECR repositories and images, the orchestration (Step Functions, CodeBuild) and the Terraform state live in the DR region, so recovery can start while the primary region is unavailable.
- Each service keeps its own infrastructure code in its own repo; the DR orchestration applies it in the DR region.

Single-AZ failures are not handled here: they are absorbed by the services themselves (Multi-AZ).

## Lambdas

`main.tf` has one `module "lambda_container"` call per lambda in the lambdas repository; the module name and the folder names must match (`<prefix>-<service>-<name>` for the function, `<ecr_prefix>/<service>/<name>` for the repository). The lambdas repository builds and pushes the images and runs `aws lambda update-function-code`, so Terraform only manages infrastructure (it ignores `image_uri` changes).

The ECR repositories are created by the lambdas repository, not here: the module only looks them up (`data "aws_ecr_repository"`) and checks that the `image_tag` image exists (`data "aws_ecr_image"`), so the plan fails with a clear error if the repository or the first image is missing.

Adding a lambda, in this order:

1. Lambdas repository: add the folder and its `module "ecr_repository"` call, and apply it (creates the repository).
2. Lambdas repository: merge to `main`; its CD pushes the first image (the `update-function-code` step is skipped while the function does not exist).
3. This repo: add the `module "lambda_container"` call and apply it (creates the function from that image).

Migration note: the module used to create the repositories. Its `removed` blocks forget them without destroying them; apply the lambdas repository first (it imports them), apply this repo, then delete the `removed` blocks.

## CI / CD

- **Terraform plan** (`ci.yml`, on pull requests touching the Terraform files or `.github/`): runs `fmt`, `validate` and `plan` with the read-only role `AWS_PLAN_ROLE_ARN` and posts the plan as a PR comment (updated on every push). Nothing is applied from a PR.
- **Terraform apply** (`cd.yml`, on push to `main` touching the Terraform files): waits for approval of the `prod` environment (required reviewer), then plans and applies the saved plan with `AWS_APPLY_ROLE_ARN`. That role is scoped to the `coika-*` resources. It can also update its own permissions and the plan role's (they match the prefix), so review changes to `github_oidc*.tf` carefully before approving the `prod` environment. The only manual apply is the one that first creates these roles (or the one that lifts a restriction the live policy still has).
- Runs are queued, never cancelled: killing Terraform halfway can leave the state locked.

## GitHub configuration (Settings > Secrets and variables > Actions)

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `AWS_PLAN_ROLE_ARN` | Read-only role for `terraform plan` on PRs |
| Secret | `AWS_APPLY_ROLE_ARN` | Role for `terraform apply` (environment `prod`) |
| Secret | `ALERT_EMAIL` | Email that receives the alarm notifications (kept out of the public plan comment) |
| Variable | `AWS_REGION` | **DR region** (`dr_region`) |
| Variable | `LAMBDA_NAME_PREFIX` | `name_prefix` |
| Variable | `ECR_REPOSITORY_PREFIX` | `ecr_prefix`, e.g. `coika/disaster_recovery` |
| Variable | `HEALTH_CHECK_URL` | Backend health endpoint checked by `health_check` |

The roles trust GitHub through OIDC (`token.actions.githubusercontent.com`): the plan role trusts pull requests of this repository, the apply role its `prod` environment. The lambdas repository has its own roles (created by its own Terraform).

## License

[MIT](LICENSE) (c) 2026 Alejandro Cortés Cabrejas.
