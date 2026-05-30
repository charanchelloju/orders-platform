# orders-platform

Event-driven microservices platform built for interview prep & DevOps experimentation.

## Architecture

```
                                       ┌──────────────────────┐
                                       │  Kafka cluster       │
                                       │  3 brokers (KRaft)   │
                                       │                      │
                                       │  Topics:             │
                                       │   orders        (6P) │
                                       │   payments      (3P) │
                                       │   notifications (3P) │
                                       │   *.DLT         (3P) │
                                       └──────────────────────┘
                                          ▲    ▲    ▲    ▲
            publishes ──────────────────┐ │    │    │    │
                                        │ │    │    │    │
            ┌───────────────────────────┴─┴─┐  │    │    │
            │  order-service                │  │    │    │
            │  • REST: POST /api/orders     │  │    │    │
            │  • Producer → orders          │  │    │    │
            │  • Consumer ← payments        │◄─┘    │    │
            │  • Transactional outbox       │       │    │
            │  • Postgres (schema: orders)  │       │    │
            └───────────────────────────────┘       │    │
                                                    │    │
            ┌───────────────────────────────────────┴┐   │
            │  payment-service                       │   │
            │  • Consumer ← orders                   │   │
            │  • Producer → payments                 │   │
            │  • Postgres (schema: payments)         │   │
            │  • DLT: payments.DLT                   │   │
            └────────────────────────────────────────┘   │
                                                         │
            ┌────────────────────────────────────────────┤
            │  inventory-service                         │
            │  • Consumer ← orders                       │
            │  • Postgres (schema: inventory)            │
            │  • Idempotent processing                   │
            └────────────────────────────────────────────┘

            ┌────────────────────────────────────────────┘
            │  notification-service
            │  • Consumer ← orders, payments
            │  • Mocks email/SMS (logs to console)
            │  • Stateless
            └─────
```

## Services

| Service | Role | REST | Producer | Consumer | DB schema |
|---------|------|------|----------|----------|-----------|
| order-service | Order intake, lifecycle | ✅ POST /api/orders | orders | payments | orders |
| payment-service | Mock payment processing | ❌ | payments | orders | payments |
| inventory-service | Stock decrements | ❌ | — | orders | inventory |
| notification-service | Mock email/SMS | ❌ | — | orders, payments | — |

## Profiles

### `local` (Docker Compose)
- Postgres 16 (one container, multiple schemas)
- Kafka cluster: 3 brokers in KRaft mode
- All 4 services running as containers

### `aws` (EKS + RDS)
- RDS Postgres (db.t3.micro, free tier)
- Kafka: self-managed 3-broker cluster via Strimzi operator (MSK not free tier)
- EKS cluster with Helm-deployed services
- ECR for container images
- Spin up for a one-day demo, tear down to save costs

## Quick start (local)

```bash
# Build all services
./scripts/build-all.sh

# Bring up the full stack
docker compose up -d --build

# Verify
curl http://localhost:8081/actuator/health         # order-service
curl http://localhost:8082/actuator/health         # payment-service
curl http://localhost:8083/actuator/health         # inventory-service
curl http://localhost:8084/actuator/health         # notification-service

# Create an order
curl -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":"keyboard","quantity":2,"customerId":"user-42"}'

# Watch the event flow across services
docker compose logs -f
```

## What this project demonstrates

- ✅ Event-driven microservices with Kafka
- ✅ Multi-broker Kafka cluster (KRaft mode, no ZooKeeper)
- ✅ Multiple topics with different partition counts
- ✅ Multiple consumer groups, independent scaling
- ✅ Transactional outbox pattern (solves dual-write problem)
- ✅ Dead Letter Topics + retry semantics
- ✅ At-least-once delivery + idempotent consumers
- ✅ Docker multi-stage builds, non-root containers
- ✅ Docker Compose for local dev
- ✅ Kubernetes deployments via Helm
- ✅ GitHub Actions CI/CD (build → test → push to ECR → deploy)
- ✅ Terraform for AWS infrastructure (EKS + RDS)
- ✅ Spring Boot 3.3 + Java 17
- ✅ Observability (Actuator + Prometheus metrics, Grafana, Loki, Fluent Bit)
- ✅ Public access via a single ALB with path-based routing
- ✅ Admin UIs (Grafana / Prometheus / AlertManager / ArgoCD) on the same ALB
- ✅ Event-driven serverless: Java Lambda + EventBridge cron for archival
- ✅ AWS Secrets Manager + IRSA + External Secrets Operator
- ✅ S3 lifecycle policies for archival (Standard → Glacier → Deep Archive)

## Project structure

```
orders-platform/
├── services/                          ← 4 Spring Boot apps + 1 Lambda
│   ├── order-service/
│   ├── payment-service/
│   ├── inventory-service/
│   ├── notification-service/
│   └── lambdas/
│       └── archive-orders/            ← Java 17 Lambda (Postgres → S3)
├── infrastructure/
│   ├── docker-compose.yml             ← local dev stack
│   ├── postgres/init.sql              ← schema bootstrap
│   ├── kafka/                         ← Strimzi K8s manifests
│   └── kind/                          ← local k8s cluster config
├── helm/                              ← Helm charts
│   ├── order-service/
│   ├── payment-service/
│   ├── inventory-service/
│   ├── notification-service/
│   ├── orders-ingress/                ← shared ALB Ingress for 4 services
│   ├── monitoring-ingress/            ← /grafana /prometheus /alertmanager
│   └── argocd-ingress/                ← /argocd
├── gitops/applications/               ← ArgoCD Application manifests
├── terraform/                         ← AWS EKS + RDS + ALB Controller + Lambda
└── .github/workflows/                 ← CI/CD
```

## Public access on AWS (ALB Ingress)

In the `aws` profile, all 4 services are exposed publicly through a single
internet-facing AWS Application Load Balancer using path-based routing.

```
   Internet
      │
      ↓ HTTP :80
   AWS ALB (auto-created by aws-load-balancer-controller)
   Rules:
     /api/orders/*        → order-service:8081
     /api/payments/*      → payment-service:8082
     /api/inventory/*     → inventory-service:8083
     /api/notifications/* → notification-service:8084
      │
      ↓
   K8s Services (ClusterIP) → Pods
```

How it's wired together:

- **Terraform** (`terraform/alb-controller.tf`) installs the AWS Load
  Balancer Controller into `kube-system` with an IRSA-bound IAM role.
- **Helm chart** (`helm/orders-ingress/`) renders a single `Ingress`
  resource with 4 path-based rules.
- **ArgoCD** syncs the chart from Git (`gitops/applications/orders-ingress.yaml`).
- The controller watches the Ingress and provisions one ALB + one target
  group per service, registering pod IPs directly (`target-type: ip`).

Get the ALB DNS name:

```bash
kubectl get ingress -n orders-platform orders-platform-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Then call any service through it:

```bash
ALB=$(kubectl get ingress -n orders-platform orders-platform-ingress \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -X POST http://$ALB/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"productId":"keyboard","quantity":2,"customerId":"alice"}'
```

**Phase 2 (future):** Route 53 + ACM cert for `https://api.orders-platform.dev/...`,
and optionally AWS API Gateway in front with Cognito JWT validation +
per-route throttling. At that point the ALB scheme flips to `internal`
and API Gateway reaches it via a VPC Link.

## Admin UIs on the same ALB

Grafana, Prometheus, AlertManager and ArgoCD are exposed through the same
ALB via the `alb.ingress.kubernetes.io/group.name` annotation. Three
Ingress resources in three namespaces merge onto one ALB.

```
http://<alb-dns>/grafana       → Grafana       (admin / admin)
http://<alb-dns>/prometheus    → Prometheus
http://<alb-dns>/alertmanager  → AlertManager
http://<alb-dns>/argocd        → ArgoCD        (admin / from secret)
```

Sub-path routing requires upstream config so each app knows its prefix:

- Grafana — `serve_from_sub_path: true` + `root_url`
- Prometheus / AlertManager — `--web.route-prefix` + full `externalUrl`
- ArgoCD — `server.rootpath` + `server.basehref`

All wired in `terraform/monitoring.tf` and `terraform/argocd.tf`.

ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Serverless: weekly order archival

Old orders (older than 6 months) are moved from Postgres → S3 by a Java
Lambda running on a weekly EventBridge schedule. Keeps the hot table small;
preserves history cheaply in S3.

```
   EventBridge cron (Sun 03:00 UTC)
              ↓
   archive-orders Lambda (Java 17, fat JAR)
              ↓
   1. Read 5,000 oldest orders from orders.orders
   2. Upload as CSV to S3 archive bucket
   3. DELETE same rows in the same transaction
              ↓
   S3 lifecycle: Standard → Glacier (90d) → Deep Archive (365d)
```

- Code: [services/lambdas/archive-orders/](services/lambdas/archive-orders/)
- Terraform: [terraform/lambdas.tf](terraform/lambdas.tf), [terraform/eventbridge.tf](terraform/eventbridge.tf), [terraform/s3-reports.tf](terraform/s3-reports.tf)
- Runtime: `java17` with `snap_start` enabled (cold start ~5s → <1s)
- IAM least-privilege: only `db_master` secret + `archive` bucket
- VPC-attached so JDBC can reach RDS over private subnets
- Memory 1 GB, timeout 5 minutes (sized for 5 000-row batches)

Build the JAR and update the Lambda:

```bash
cd services/lambdas/archive-orders
mvn clean package -DskipTests

cd ../../../terraform
terraform apply -target=aws_lambda_function.archive_orders
```

Invoke manually (for testing — production runs from EventBridge):

```bash
aws lambda invoke \
  --function-name orders-platform-archive-orders \
  --region ap-south-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' response.json
cat response.json
# {"archived":42,"s3Key":"archive/orders/2026-05-30/orders-1717094400.csv","statusCode":200}
```

**Why Lambda for this and not a K8s CronJob?** Workload runs once a week
for ~5 minutes — paying for an always-on pod (or even a CronJob using node
capacity) is wasteful. Lambda's per-millisecond pricing means this costs
under $0.05/month. Cold start (~5s) is irrelevant because no user is
waiting for the response.

## License

MIT
