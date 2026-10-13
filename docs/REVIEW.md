# Revisión de buenas prácticas de producción

Checklist de la revisión del repo. Marca cada punto al corregirlo. Las referencias `archivo:línea` son de
la revisión original y pueden haberse movido.

## Críticos / altos

- [x] **1. El rol de apply puede escalar privilegios** (`github_oidc_apply.tf`)
  - Permissions boundary (`iam_boundary.tf`) en todos los roles del repo; el apply solo crea/toca roles con boundary.
  - Deny explícito sobre los roles plan/apply y sobre quitar boundaries.
  - Los cambios en `github_oidc*.tf` e `iam_boundary.tf` los aplica un administrador, no el pipeline.
  - Aplicado y verificado en la cuenta: boundary creado, 11 roles del repo lo llevan, plan/apply sin boundary, política de apply con los statements nuevos.
  - [x] `failover_plan` ejecutado tras el apply (2026-10-13): SUCCEEDED, el build `-up` con `TF_ACTION=plan` también. Solo prueba el rol de CodeBuild; las Lambdas y el resto de state machines solo se prueban en un failover real.
- [ ] **2. La confianza OIDC de apply no restringe la rama** (`github_oidc_apply.tf:24-28`)
  - [x] Trust policy: condiciones `ref` y `job_workflow_ref` (variables `github_repository`, `github_apply_branch`, `github_apply_workflow`). Aplicado y verificado en la cuenta.
  - [x] GitHub: environment `prod` con *Deployment branches* = solo `main`. *Prevent self-review* desactivado a propósito (un único mantenedor); activarlo si entra otra persona.
- [ ] **3. La aprobación del apply es "a ciegas"** (`cd.yml:31, 59-64`)
  - [x] `cd.yml` en dos jobs: `terraform-plan` (sin approval, rol de plan, muestra el plan en el resumen y sube `tfplan` cifrado) y `terraform-apply` (`environment: prod`, aplica ese plan).
  - [x] Trust del rol de plan ampliada a `ref:refs/heads/main` (`github_oidc.tf`).
  - [ ] Crear el secret `PLAN_ENCRYPTION_KEY` (`openssl rand -base64 32`), el repo es público.
  - [ ] Aplicar `github_oidc.tf` como administrador **antes** de mergear.
  - [ ] Probar con un `workflow_dispatch` desde `main`.
- [ ] **4. `ssm:SendCommand` sobre cualquier instancia** (`main.tf`, módulos `restore_db` y `backup_db`)
  - Condición por tag (`ssm:resourceTag/Name` o `aws:ResourceTag/Name` = `db_instance_name`) en vez de `instance/*`.
- [ ] **5. Comodines de servicio en el rol de apply** (`github_oidc_apply.tf`)
  - Sustituir `states:*`, `codebuild:*`, `lambda:*`, `dynamodb:*`, `sns:*` y `logs:*` por acciones enumeradas.
  - `lambda:*` permite invocar `restore_db`; `dynamodb:*` permite escribir el lock de failover.
- [ ] **6. El boundary del rol de CodeBuild se puede reescribir** (`codebuild.tf`, `IamBoundaryPolicy`)
  - Quitar `CreatePolicyVersion`/`SetDefaultPolicyVersion` sobre `*-ci-boundary*` de la política del build.
- [ ] **7. Cadena de suministro del failover** (`variables.tf`, `codebuild.tf`, `failover/buildspec-up.yml`)
  - Fijar `service_repo_ref` a tag o commit (no `main`).
  - Verificar checksum/firma de Terraform.
  - Eliminar dependencias externas durante el desastre (hashicorp releases, registry de providers, GitHub): imagen propia o mirror en S3/ECR.
- [ ] **8. Monitoreo del DR incompleto** (`main.tf`, `alarms.tf`)
  - Activar el schedule del `health_check` (hoy comentado) revisando la alarma (`treat_missing_data = breaching`).
  - Alarmas sobre la propia maquinaria: ejecuciones fallidas de Step Functions, errores de Lambda, builds fallidos, estado `FAILING_OVER`/`FAILING_BACK` atascado, heartbeat del health check.
  - Más de un punto de vista para decidir que el backend está caído (p. ej. Route 53 Health Checks).
  - Segundo canal de alerta además del email.
- [ ] **9. Task tokens de aprobación por email en texto plano** (`failback.tf`, `notifications.tf`)
  - Aprobaciones vía API autenticada con IAM; SSE-KMS en el topic SNS.

## Medios

- [ ] **10. `ReadOnlyAccess` en tres roles** (plan, apply, CodeBuild)
  - Política a medida con solo `Describe/List/Get` de los servicios usados.
  - Comprobar si la política administrada permite leer los dumps de la BD en S3.
- [ ] **11. Lambdas sin versionado ni alias** (`modules/lambda_container`)
  - Versiones + alias `live`, tags inmutables o digest, en vez de `latest` y `$LATEST`.
  - DLQ / on-failure destination, `reserved_concurrent_executions`, X-Ray.
- [ ] **12. Restore destructivo sin red de seguridad** (`db_backup_restore.tf`)
  - Snapshot EBS previo al restore.
  - Validar la antigüedad del dump y alarmar la latencia de replicación del bucket.
  - Definir y medir RPO/RTO.
- [ ] **13. Buckets y tabla sin endurecimiento** (`service_state.tf`, `failover_state.tf`, `versions.tf`)
  - Policy que deniegue tráfico sin TLS, logging de acceso, SSE-KMS.
  - `deletion_protection_enabled` en DynamoDB.
  - Bootstrap del bucket de estado principal como stack aparte o documentado/verificado.
- [ ] **14. Supply chain del CI** (`ci.yml`, `cd.yml`)
  - Actions fijadas por SHA de commit, no por tag.
  - Dependabot/Renovate.
  - Versión de Terraform en un único sitio (hoy en `ci.yml`, `cd.yml` y `variables.tf`).
- [ ] **15. CI sin análisis estático ni drift** (`ci.yml`)
  - `tflint`, `checkov` o `trivy config`.
  - `plan` programado para detectar drift.
  - Ensayo de DR programado (dry-run `failover_plan`) y comprobación de la conexión CodeConnections (nace `PENDING`).
  - Revisar los filtros `paths:` frente a *required checks*.
- [ ] **16. Defaults específicos del entorno en el código** (`variables.tf`)
  - Quitar el default de `github_sub_prefix`, `service_state_bucket`, `service_ssh_public_key`, `service_repo_url` (IDs de cuenta/repo, clave SSH).

## Bajos / higiene

- [ ] **17. Nombres inconsistentes con `name_prefix`** (`notifications.tf`, `github_oidc.tf`, `github_oidc_apply.tf`)
  - Topic SNS y roles plan/apply tienen `coika-...` fijo mientras los permisos usan `${var.name_prefix}-*`.
- [ ] **18. Tags mínimos** (`versions.tf`): añadir `Environment`, `Owner`, `CostCenter`.
- [ ] **19. Logs de Step Functions** (todas las state machines)
  - Nivel `ALL` para el failover real, X-Ray, KMS en los log groups, retención acorde a auditoría.
- [ ] **20. Buildspecs sin `set -euo pipefail`** (`failover/*.yml`)
  - Salvaguarda técnica de que el último dump está replicado antes del `terraform destroy -auto-approve` del `-down`.
- [ ] **21. Variables del módulo sin descripción ni `validation`** (`timeout`, `memory_size`, `log_retention_days`, `primary_recovery_*`, `dr_region != primary_region`).
- [ ] **22. `docs/runbooks/` y `scripts/` vacíos**
  - Runbooks para los pasos manuales: parar la API, cambiar DNS, reset del estado `FAILING_BACK`.
- [ ] **23. El cambio de DNS es manual** (decisión de arquitectura)
  - Valorar Route 53 failover routing con health checks.

## Observaciones surgidas durante las correcciones

- [ ] `iam:PassRole` del rol de apply no incluye `events.amazonaws.com`, pero `aws_cloudwatch_event_target.failover` usa `role_arn`. Verificar si el apply del pipeline lo necesita.
- [ ] El Deny del CodeBuild sobre roles con boundary no cubre `iam:UpdateAssumeRolePolicy` ni tags (la condición `iam:PermissionsBoundary` no aplica a esas acciones).
