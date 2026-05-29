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
├── helm/                              ← one chart per service
├── terraform/                         ← AWS EKS + RDS
├── .github/workflows/                 ← CI/CD
└── docs/                              ← architecture diagrams
```

## License

MIT
