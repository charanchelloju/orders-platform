# Running locally (Docker Desktop)

This guide walks through running the entire `orders-platform` stack on your laptop with **Docker Compose** — no cloud, no K8s, fully offline.

## Prerequisites

- Docker Desktop with at least **6 GB RAM** allocated (Settings → Resources)
- ~5 GB free disk space (Kafka volumes + container images)
- ports `5432, 8081-8085, 8090, 9092-9094` available on host

## Bring up the stack

```powershell
cd c:\Users\suman\git\orders-platform

# Build all 4 service images + start everything
docker compose up -d --build

# Wait ~60s for Kafka cluster + services to finish startup
docker compose ps
```

You should see all containers as `Up (healthy)` or `Up (running)`:

```
NAME                    STATUS
postgres                Up (healthy)
kafka-1                 Up (healthy)
kafka-2                 Up (healthy)
kafka-3                 Up (healthy)
kafka-ui                Up
order-service           Up
payment-service         Up
inventory-service-1     Up
inventory-service-2     Up
notification-service    Up
```

## Verify each service

```bash
curl http://localhost:8081/actuator/health    # order-service
curl http://localhost:8082/actuator/health    # payment-service
curl http://localhost:8083/actuator/health    # inventory-service-1
curl http://localhost:8085/actuator/health    # inventory-service-2
curl http://localhost:8084/actuator/health    # notification-service
```

## Create an order — watch the cascade

```bash
curl -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"user-42","productId":"keyboard","quantity":2}'
```

Watch the event flow ripple across services:

```bash
docker compose logs -f order-service payment-service inventory-service-1 notification-service
```

You should see, in order:
1. `order-service` saves the order, writes to outbox
2. Outbox publisher pushes `OrderCreated` event to `orders` topic
3. `payment-service` consumes from `orders`, mocks payment, publishes to `payments`
4. `order-service` consumes from `payments` and marks the order PAID
5. `inventory-service` consumes from `orders` and decrements stock
6. `notification-service` consumes from both `orders` and `payments`, logs mock emails

## Watch Kafka topics, groups, and lag in the UI

Open <http://localhost:8090>:

- **Topics** → see `orders`, `payments`, `*.DLT`, `__consumer_offsets` (50 internal partitions)
- **Consumer Groups** → see `order-service`, `payment-service`, `inventory-service`, `notification-service` with per-partition lag
- **Brokers** → 3 brokers, see which is the active controller

## Explore Kafka concepts

### See partition leaders
```bash
docker compose exec kafka-1 kafka-topics --bootstrap-server kafka-1:29092 --describe --topic orders
```

### Watch consumer group lag
```bash
docker compose exec kafka-1 kafka-consumer-groups --bootstrap-server kafka-1:29092 \
  --describe --group inventory-service
```

### See the rebalance happen — kill one inventory-service
```bash
docker compose stop inventory-service-1
docker compose exec kafka-1 kafka-consumer-groups --bootstrap-server kafka-1:29092 \
  --describe --group inventory-service
# inventory-service-2 now owns all partitions
docker compose start inventory-service-1
# Rebalance — partitions redistribute back
```

### Scale a service up
```bash
docker compose up -d --scale notification-service=3 --no-recreate
```

## Tear down

```bash
docker compose down              # keeps volumes
docker compose down -v           # full reset, deletes Postgres + Kafka data
```

## Common issues

| Symptom | Fix |
|---------|-----|
| Kafka brokers stuck "starting" | Increase Docker RAM to 6+ GB |
| `Connection refused` on POST | Wait — services take 30-60s to be healthy |
| `Topic not present in metadata` | Brokers not fully joined; restart with `docker compose restart kafka-1 kafka-2 kafka-3` |
| Port conflict on 9092 | Stop any locally-running Kafka (`netstat -ano | findstr 9092` on Windows) |
