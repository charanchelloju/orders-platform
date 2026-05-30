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
- ✅ Observability (Actuator + Prometheus metrics)

## Project structure

```
orders-platform/
├── services/                          ← 4 independent Spring Boot apps
│   ├── order-service/
│   ├── payment-service/
│   ├── inventory-service/
│   └── notification-service/
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
│   └── orders-ingress/                ← shared ALB Ingress for all 4 services
├── gitops/applications/               ← ArgoCD Application manifests
├── terraform/                         ← AWS EKS + RDS + ALB Controller
├── .github/workflows/                 ← CI/CD
└── docs/                              ← architecture diagrams
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

## License

MIT
