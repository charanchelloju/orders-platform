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

## Authentication architecture (two patterns coexisting)

The project ships both auth patterns side by side so the same JWT can be
validated either by each backend service (Pattern 1) or once at an edge
gateway (Pattern 2). Toggle via the `keycloak.issuerUri` Helm value on
the backend service.

```
                        Pattern 1                      Pattern 2
                  (per-service Security)         (centralized gateway)
                  ─────────────────────         ─────────────────────
   Browser              ↓ JWT                            ↓ JWT
   ALB           /api/orders/* ─→ order-svc       /api/** ─→ api-gateway
                  (Spring Sec. validates)         (validates, rate limits,
                                                   injects X-User-* headers)
                                                            ↓
                                                  order-svc, payment-svc,
                                                  inventory-svc, notification
                                                  (trust headers, no JWT logic)
```

**When to pick which:**
- Pattern 1 = small teams, < 10 services, no extra hop, every service handles its own auth.
- Pattern 2 = 10+ services, central rate limit, IdP swap in one place.

Both backed by the same Keycloak in this repo - changing the IdP (to
Azure AD, Okta, etc.) is a one-line `issuer-uri` change in either layer.

## Authentication (Keycloak + Spring Security)

`order-service` validates Bearer JWTs against Keycloak running in the same
cluster at `/auth`. Other services are pure Kafka consumers with no HTTP
endpoints — they don't need auth.

```
   Browser ─→ ALB ─→ /auth/*        ─→ Keycloak (issues JWTs)
                     /api/orders/*  ─→ order-service (validates JWT)
```

### How it's wired

- **Keycloak deployment** runs as a single pod in the `keycloak` namespace,
  exposed at `/auth` on the shared ALB via the `group.name` annotation
  (`helm/keycloak-ingress/`).
- **Admin password** is generated by Terraform (`random_password`), stored
  in AWS Secrets Manager (`orders-platform/keycloak/admin`), and synced
  into a K8s Secret via External Secrets Operator. No plain credentials
  anywhere in git.
- **Spring Security** in order-service (`SecurityConfig.java`) uses
  `spring-boot-starter-oauth2-resource-server`. When the issuer URI is
  set, every `/api/**` request requires a valid JWT; without it, the
  service runs open (local dev / CI tests).
- **Roles** are mapped from the Keycloak `realm_access.roles` claim to
  `ROLE_*` Spring authorities. Controllers use `@PreAuthorize`:
  ```java
  @PreAuthorize("hasRole('ORDERS_WRITE')")  // POST /api/orders
  @PreAuthorize("hasRole('USER')")          // GET  /api/orders
  ```

### One-time realm setup

After the cluster is up and Keycloak is running, bootstrap the realm:

```powershell
# Terminal 1 — keep this open
kubectl port-forward -n keycloak svc/keycloak 8080:80

# Terminal 2 — run the bootstrap script
.\scripts\keycloak-setup.ps1
```

This creates:

| Object | Value |
|--------|-------|
| Realm | `orders` |
| Client | `orders-app` (public, direct grants enabled) |
| Roles | `USER`, `ORDERS_WRITE`, `ORDERS_READ` |
| Users | `alice` / `alice` (all roles), `bob` / `bob` (read-only) |

### Get a token and call the API

```bash
ALB=k8s-ordersplatform-e8323cc06c-1834496908.ap-south-1.elb.amazonaws.com

TOKEN=$(curl -s -X POST "http://$ALB/auth/realms/orders/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=orders-app \
  -d username=alice -d password=alice | jq -r .access_token)

# alice has ORDERS_WRITE → 200
curl -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"customerId":"alice","productId":"keyboard","quantity":2}'

# Without token → 401
curl -X POST "http://$ALB/api/orders" -H 'Content-Type: application/json' \
  -d '{"customerId":"alice","productId":"x","quantity":1}'

# bob (only USER + ORDERS_READ) on POST → 403
TOKEN_BOB=$(curl -s -X POST "http://$ALB/auth/realms/orders/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=orders-app \
  -d username=bob -d password=bob | jq -r .access_token)
curl -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  -H 'Content-Type: application/json' \
  -d '{"customerId":"bob","productId":"x","quantity":1}'
```

### Switching to Azure AD later

The Spring config is IdP-agnostic — change one line:

```yaml
spring.security.oauth2.resourceserver.jwt.issuer-uri:
  https://login.microsoftonline.com/<tenant-id>/v2.0
```

Update the role mapping in `SecurityConfig.java` from `realm_access.roles`
to `roles` (Azure AD app roles), rename app roles to match the existing
`@PreAuthorize` constants, and the migration is done. No business code
changes.

## Spring Cloud Gateway (Pattern 2)

Adds a Spring Cloud Gateway pod in front of the backend services. Same
Keycloak JWT, validated once at the gateway. The gateway:

1. Validates the Bearer JWT against Keycloak's JWKS endpoint.
2. Strips the `Authorization` header.
3. Injects user identity downstream:
   - `X-User-Id`      (JWT sub)
   - `X-User-Name`    (preferred_username)
   - `X-User-Email`   (email)
   - `X-User-Roles`   (comma-joined realm roles)
4. Rate limits **per user** using a Redis token bucket - 100 req/min
   sustained, 200 burst.
5. Routes by path to the in-cluster Service of each backend.

```
   Browser ─→ ALB :80 ─→ api-gateway (validates JWT, rate-limit, headers)
                              ↓ plain HTTP, no JWT
                          ┌────┴───────────────────────────┐
                          ↓               ↓                ↓
                       order-svc    payment-svc      inventory-svc
                      (X-User-*)    (X-User-*)        (X-User-*)
```

### Files

- [services/api-gateway/](services/api-gateway/) - Spring Boot 3.3 + Spring
  Cloud Gateway 2023.0, reactive Spring Security resource server, Redis
  rate-limit filter, `HeaderInjectionFilter` global filter.
- [helm/api-gateway/](helm/api-gateway/) - chart deployed via ArgoCD.
- [helm/redis/](helm/redis/) - tiny in-cluster Redis (rate-limit counters only).
- [helm/orders-ingress/values.yaml](helm/orders-ingress/values.yaml) -
  single ALB rule now sends all `/api/**` to the gateway.

### Backend services in Pattern 2 mode

Leave `keycloak.issuerUri` set and the service still validates the JWT
itself (Pattern 1 - belt and suspenders). Set it to an empty string and
the existing `SecurityConfig` swaps to its open `SecurityFilterChain`,
trusting the `X-User-*` headers from the gateway. The toggle is one Helm
value, no code change.

### Rate limit behaviour

Each authenticated user gets their own token bucket keyed by `sub`. Burst
above the limit returns `HTTP 429 Too Many Requests` with `X-RateLimit-*`
headers. Anonymous traffic shares one bucket so a missing JWT can't
bypass per-user limits.

### Demo

```bash
ALB=k8s-ordersplatform-e8323cc06c-1834496908.ap-south-1.elb.amazonaws.com

# Get alice's JWT (Keycloak)
TOKEN=$(curl -s -X POST "http://$ALB/auth/realms/orders/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=orders-app \
  -d username=alice -d password=alice | jq -r .access_token)

# Same /api/orders endpoint - now routed through the gateway
curl -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"customerId":"alice","productId":"keyboard","quantity":2}'

# Burst test - 250 calls in a row, expect 429 once the bucket runs out
for i in $(seq 1 250); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    "http://$ALB/api/orders" &
done | sort | uniq -c
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
