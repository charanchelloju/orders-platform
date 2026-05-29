# Secrets Manager + IRSA + External Secrets Operator — Production Pattern

This doc explains the production-grade secret-handling pattern added to
`orders-platform`, which replaces the demo `var.db_password` approach.

## Why

The original setup typed a password into `terraform.tfvars`. That has problems:

- Plaintext password sits on developer laptops
- Password is in `terraform.tfstate` (also plaintext)
- Manual K8s Secret creation steps in `docs/AWS.md`
- No password rotation
- No least-privilege per service

This setup eliminates all of that.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   Terraform:                                                             │
│     1. random_password.db_master      ← generated, never typed          │
│     2. aws_secretsmanager_secret.*    ← stored in AWS                    │
│     3. aws_db_instance.postgres       ← uses generated password          │
│     4. IAM roles per service (IRSA)   ← scoped permissions               │
│                                                                          │
│   AWS Secrets Manager:                                                   │
│     /orders-platform/rds/master                                          │
│     /orders-platform/rds/order_service     ← per-service credentials     │
│     /orders-platform/rds/payment_service                                 │
│     /orders-platform/rds/inventory_service                               │
│                                                                          │
└─────────────────────────────┬────────────────────────────────────────────┘
                              │ (read via IRSA-authenticated calls)
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   External Secrets Operator (ESO) — installed in EKS                     │
│                                                                          │
│     ESO ServiceAccount (external-secrets-sa)                             │
│        annotated with IRSA role ARN (read all service secrets)           │
│                                                                          │
│     ClusterSecretStore "aws-secrets-manager"                             │
│        configured for region + auth method                               │
│                                                                          │
│   For each microservice, an ExternalSecret resource:                     │
│     "Fetch /orders-platform/rds/order_service from Secrets Manager       │
│      every hour, project into K8s Secret 'order-service-db'"             │
│                                                                          │
└─────────────────────────────┬────────────────────────────────────────────┘
                              │ ESO syncs secret values
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   K8s Secret 'order-service-db' (created and maintained by ESO)          │
│     SPRING_DATASOURCE_URL                                                │
│     SPRING_DATASOURCE_USERNAME                                           │
│     SPRING_DATASOURCE_PASSWORD                                           │
│                                                                          │
└─────────────────────────────┬────────────────────────────────────────────┘
                              │ envFrom: secretRef
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   order-service pod                                                      │
│     - Uses ServiceAccount 'order-service-sa'                             │
│       (annotated with its own IRSA role, scoped to read only its         │
│        own secret directly if needed)                                    │
│     - Receives SPRING_DATASOURCE_* as env vars                           │
│     - Spring Boot connects to RDS                                        │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Two layers of IRSA

| Layer | ServiceAccount | IAM role | Why |
|-------|---------------|----------|-----|
| ESO controller | `external-secrets-sa` | reads ALL `/orders-platform/rds/*` secrets | ESO syncs them into K8s |
| Per-service | `order-service-sa`, `payment-service-sa`, ... | reads ONLY its own secret | Least-privilege in case app needs direct AWS calls (e.g. MSK) |

For DB access specifically, only ESO needs Secrets Manager access — apps read
the resulting K8s Secret. The per-service IRSA roles exist for OTHER AWS calls
(MSK IAM auth, S3, etc.).

## Deployment order

```bash
# 1. Provision AWS infrastructure (creates Secrets, IAM, EKS, RDS)
cd terraform/
terraform init
terraform apply

# 2. Capture outputs
ESO_ROLE_ARN=$(terraform output -raw eso_role_arn)
ORDER_ROLE_ARN=$(terraform output -json service_role_arns | jq -r '."order-service"')
# ... and so on for each service

# 3. Connect kubectl
aws eks update-kubeconfig --name orders-platform-eks --region ap-south-1

# 4. Install Strimzi + Kafka cluster (same as before)
kubectl apply -f infrastructure/kafka/...

# 5. Install ESO
export ESO_ROLE_ARN
./infrastructure/eso/install.sh

# 6. Run init.sql against RDS using the GENERATED master password
# Pull master password from Secrets Manager
MASTER_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id orders-platform/rds/master \
  --query SecretString --output text)
MASTER_PW=$(echo "$MASTER_SECRET" | jq -r .password)
RDS_HOST=$(echo "$MASTER_SECRET" | jq -r .host)

kubectl run psql-tmp --rm -it --image=postgres:16-alpine \
  --env=PGPASSWORD="$MASTER_PW" \
  -- psql -h "$RDS_HOST" -U postgres -d orders_platform < infrastructure/postgres/init.sql

# 7. Now update Postgres user passwords to match the per-service secrets
# (You'd write a small script that loops through each service secret,
#  ALTER USER ... PASSWORD '<from secret>')

# 8. Deploy services via Helm
helm upgrade --install order-service ./helm/order-service \
  --namespace orders-platform \
  --create-namespace \
  --set image.repository=$ECR_REGISTRY/order-service \
  --set image.tag=v0.1.0 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ORDER_ROLE_ARN"

# ESO will automatically create the order-service-db K8s Secret within ~30s
# Deployment env reads from it via envFrom
```

## Password rotation

Secrets Manager can rotate the RDS master password automatically:

```hcl
resource "aws_secretsmanager_secret_rotation" "db_master" {
  secret_id           = aws_secretsmanager_secret.db_master.id
  rotation_lambda_arn = aws_lambda_function.rds_rotation.arn
  rotation_rules {
    automatically_after_days = 30
  }
}
```

When the rotation happens:
1. AWS Lambda generates new password
2. ALTER USER in RDS
3. Updates Secrets Manager
4. ESO picks up new version on next refresh (1h)
5. K8s Secret updated
6. Pods need to restart OR Spring Boot's HikariCP refreshes the connection pool

Real production usually uses a `Reloader` controller to auto-restart pods
when their referenced Secret changes.

## What you'd talk about in interviews

> "Database passwords are generated by `random_password` in Terraform, stored
> in AWS Secrets Manager — never on a developer laptop. External Secrets
> Operator runs in EKS, authenticates to Secrets Manager via its own IRSA
> role, and syncs the values into K8s Secrets that pods read via envFrom.
> Each microservice has its own IRSA role for any direct AWS calls it needs.
> Rotation is automated through Secrets Manager + a Lambda. Apps and pods
> never see or store long-lived credentials."

## Comparison to demo setup

| Aspect | Demo (`var.db_password`) | Production (this) |
|--------|--------------------------|-------------------|
| Password origin | Developer types in tfvars | `random_password` resource |
| Storage on laptop | Yes (plaintext in tfvars) | Never |
| Storage in tfstate | Yes (plaintext) | Yes (still — encrypt the state backend) |
| Storage in AWS | RDS only | Secrets Manager + RDS |
| K8s Secret creation | Manual `kubectl create secret` | Automatic via ESO |
| Rotation | None | Optional via Lambda |
| Per-service scope | One shared password | One secret per service |
| Cleanup | Manual | `terraform destroy` |
