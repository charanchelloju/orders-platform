# Architecture deep-dive

## High-level flow

```
                            ┌──────────────────────────────────────┐
                            │   Kafka cluster (3 brokers, KRaft)   │
                            │                                      │
                            │   orders         (6 partitions)      │
                            │   payments       (3 partitions)      │
                            │   orders.DLT     (6 partitions)      │
                            │   payments.DLT   (3 partitions)      │
                            └────────────────────────────────────────┘
                              ▲      ▲      ▲     ▲     ▲     ▲
              publishes ──────┘      │      │     │     │     │
                                     │      │     │     │     │
     ┌───────────────────────────────┴─┐    │     │     │     │
     │  order-service                  │    │     │     │     │
     │  • POST /api/orders             │    │     │     │     │
     │  • Producer → orders            │    │     │     │     │
     │  • Consumer ← payments (group)  │◄───┘     │     │     │
     │  • Transactional outbox         │          │     │     │
     │  • Idempotent payment handling  │          │     │     │
     └─────────────────────────────────┘          │     │     │
                                                  │     │     │
              ┌───────────────────────────────────┴┐    │     │
              │  payment-service                    │   │     │
              │  • Consumer ← orders (group)        │   │     │
              │  • Producer → payments              │   │     │
              │  • Idempotent: one payment / order  │   │     │
              │  • DLT on processing failure        │   │     │
              └─────────────────────────────────────┘   │     │
                                                        │     │
              ┌─────────────────────────────────────────┘     │
              │  inventory-service (3 replicas)               │
              │  • Consumer ← orders (group)                  │
              │  • Idempotent via processed_orders log        │
              │  • Decrements stock                           │
              └────────────────────────────────────────────────┘

              ┌────────────────────────────────────────────────┘
              │  notification-service (2 replicas)
              │  • Consumer ← orders, payments (one group)
              │  • Mocks email/SMS to console
              │  • Stateless — pure side effect
              └─────
```

## Why 4 services?

Each service has a **distinct scaling profile** and **fault domain**:

| Service | Scaling driver | Failure tolerance |
|---------|--------------|-------------------|
| order-service | HTTP POST throughput | If down → no new orders. Hard fail. |
| payment-service | Payment API latency | If down → orders pile up, retried via Kafka. Soft fail. |
| inventory-service | Stock-update throughput | If down → orders processed but stock stale. Eventually consistent. |
| notification-service | Email/SMS provider rate limits | If down → no emails. Tolerable for minutes. |

In a monolith, slow email logic would back up order intake. With separation, **each service fails independently**.

## Why these partition counts?

| Topic | Partitions | Why |
|-------|-----------|-----|
| orders | 6 | Highest throughput (every order goes here). Plus 3 consumers in inventory-service (= 3) and other groups. 6 gives headroom to scale to 6 consumers/group. |
| payments | 3 | Lower volume — only order-service consumes. |
| *.DLT | matches source | Mirror failed messages 1:1 with original partition. |

**Rule**: max useful consumers per group = partition count. Start with headroom (2-3x typical replica count).

## Why transactional outbox?

`order-service` writes to **two places**:
- Postgres (the order row)
- Kafka (the `OrderCreated` event)

These can't be made atomic with two-phase commit (not supported by Kafka producers in any sensible way). So we use the **outbox pattern**:

```
Within ONE database transaction:
    INSERT INTO orders.orders (...) VALUES (...);
    INSERT INTO orders.outbox (topic, payload, ...) VALUES ('orders', '{...}');
COMMIT;

Separately, a scheduled job:
    SELECT * FROM orders.outbox WHERE published_at IS NULL ORDER BY created_at;
    FOR EACH row:
        kafka.send(row.topic, row.payload)
        UPDATE orders.outbox SET published_at = NOW() WHERE id = row.id;
```

Why this works:
- DB write and outbox row are atomic — both succeed or both fail
- Kafka publish happens later, idempotently retried until it succeeds
- Worst case: a row gets published twice (Kafka send succeeded but DB update failed) — consumers must be idempotent

**Real production**: use Debezium to stream the outbox table directly to Kafka via CDC. Same idea, no polling job.

## Why at-least-once + idempotent consumers?

All consumers use:
- `enable.auto.commit: false`
- `AckMode.MANUAL_IMMEDIATE` — commit only after processing succeeds
- DLT routing after 3 retries via `DefaultErrorHandler`

This is **at-least-once** delivery. Duplicates are possible (e.g., crash between processing and commit). Each consumer is idempotent:

| Service | Idempotency key | How |
|---------|---|---|
| order-service | `orderId` | UPDATE based on status — replaying the same status update is a no-op |
| payment-service | `orderId` (unique on Payment) | `findByOrderId` returns existing → no-op |
| inventory-service | `orderId` in `processed_orders` table | Skip if already in log |
| notification-service | (none — log is idempotent enough for demo) | Logs may duplicate; in real use add idempotency key |

## Why 3-broker Kafka?

- **Fault tolerance**: with `replication.factor=3` and `min.insync.replicas=2`, the cluster survives any 1 broker failure with zero data loss.
- **Demonstration**: 3 is the minimum count where you can talk meaningfully about leader/follower roles, ISR shrinking, controller election.
- **Local feasibility**: 3 brokers fit in Docker Desktop with 6 GB RAM. 5 would be more "real" but kills laptops.

## Why KRaft mode (no ZooKeeper)?

- Kafka 4.0 removes ZooKeeper entirely
- One less system to operate
- Modern (since Kafka 3.3 — what you'd see in 2026 production)
- Faster controller failover

## Profile differences: local vs AWS

| Aspect | `docker` (local) | `aws` (production-ish) |
|--------|-----------------|----------------------|
| Postgres | Container in compose | RDS managed instance |
| Kafka | 3-broker Confluent containers | 3-broker Strimzi cluster in EKS |
| Service discovery | Container DNS (`kafka-1:29092`) | K8s services (`kafka-cluster-kafka-bootstrap.kafka:9092`) |
| Secrets | Hard-coded in YAML (it's a demo) | K8s `Secret` objects sourced from RDS endpoints |
| Health checks | Docker healthcheck | K8s liveness/readiness probes |
| Scaling | `docker compose up --scale` | `kubectl scale deployment` |
| Image source | Built locally | Pulled from ECR |

The application code is **identical** across both — only `application.yml` profiles change.

## What's intentionally NOT included

- **Schema Registry / Avro**: keeping JSON for simplicity; in production, use Confluent Schema Registry + Avro for contract enforcement
- **Kafka Streams**: too much for an interview-prep project; would change the architecture significantly
- **OpenTelemetry tracing**: would be the natural next step; Spring Boot 3 + Micrometer Tracing makes it trivial to add
- **Saga choreography for failure compensation**: a real e-commerce platform would compensate failed payments (revert stock decrement, send refund email); kept out for simplicity
- **API gateway / authentication**: order-service is exposed directly — in production add Kong/Ambassador + OAuth/JWT

These are great talking points for "what would you add next?" in an interview.
