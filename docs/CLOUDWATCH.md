# CloudWatch — AWS-managed observability

## Split of responsibilities

```
┌──────────────────────────────────────────────────────────────────────┐
│  Application logs + metrics + Kafka:                                 │
│      Loki + Prometheus → Grafana                                     │
│      (see docs/MONITORING.md)                                        │
│                                                                      │
│  AWS-managed services:                                                │
│      CloudWatch                                                       │
│      • EKS control plane (audit, API)                                 │
│      • RDS Postgres logs + Performance Insights                       │
│      • NAT Gateway, ECR, EBS metrics                                  │
│      • Alarms → SNS → email                                           │
└──────────────────────────────────────────────────────────────────────┘
```

This split matches what most mid-size AWS shops actually do.

## What's added

| Component | File | What |
|-----------|------|------|
| EKS control plane logging | [terraform/eks.tf](../terraform/eks.tf) | Streams API/audit/scheduler logs to CloudWatch |
| RDS Performance Insights | [terraform/rds.tf](../terraform/rds.tf) | Top SQL by load dashboard |
| RDS enhanced monitoring | [terraform/rds.tf](../terraform/rds.tf) | Per-second OS metrics to CloudWatch |
| RDS Postgres log export | [terraform/rds.tf](../terraform/rds.tf) | Slow queries, errors, connection logs |
| 5 critical alarms | [terraform/cloudwatch.tf](../terraform/cloudwatch.tf) | RDS CPU/storage/connections + NAT errors + EKS node CPU |
| SNS topic + email subscription | [terraform/cloudwatch.tf](../terraform/cloudwatch.tf) | One-hop alert routing |

## Bootstrap

After `terraform apply`:

1. **Confirm the SNS subscription**
   - AWS sends an email to `alert_email` from your tfvars
   - Click the confirmation link inside
   - Until confirmed, alarms fire but emails don't deliver

2. **Verify log groups exist**
   ```bash
   aws logs describe-log-groups \
     --log-group-name-prefix /aws/eks/orders-platform-eks/

   aws logs describe-log-groups \
     --log-group-name-prefix /aws/rds/instance/orders-platform-postgres/
   ```

3. **Generate some load to see metrics**
   ```bash
   # Hit the order endpoint
   for i in {1..100}; do
     curl -X POST http://<svc>/api/orders \
       -H "Content-Type: application/json" \
       -d "{\"customerId\":\"u$i\",\"productId\":\"x\",\"quantity\":1}"
   done
   ```

4. **Browse the Console**

   AWS Console → CloudWatch → Log groups → see logs flowing in.

## What you'll see in AWS Console

### CloudWatch → Log groups
```
/aws/eks/orders-platform-eks/cluster      ← EKS audit, API requests
/aws/rds/instance/orders-platform-postgres/postgresql   ← slow queries, errors
/aws/rds/instance/orders-platform-postgres/upgrade      ← maintenance events
```

Click any log group → **Logs Insights** for SQL-like queries:

```
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 50
```

### CloudWatch → Metrics → RDS
- CPUUtilization
- DatabaseConnections
- FreeStorageSpace
- ReadIOPS / WriteIOPS
- ReplicaLag (if you add a replica)

### CloudWatch → Alarms
```
   orders-platform-rds-cpu-high           OK
   orders-platform-rds-storage-low        OK
   orders-platform-rds-connections-high   OK
   orders-platform-nat-errors             OK
   orders-platform-eks-node-cpu-high      OK
```

### RDS → Performance Insights
- Top SQL by **load** (DB time per second)
- Wait events (lock waits, CPU, IO)
- Per-database / per-user filters
- Free with 7-day retention

## Useful Logs Insights queries

```
# All Postgres errors in last hour
fields @timestamp, @message
| filter @logStream like /postgresql/
  and @message like /ERROR/
| sort @timestamp desc

# Connection-related events
fields @timestamp, @message
| filter @message like /connection/

# Slow queries (configured via log_min_duration_statement in RDS parameter group)
fields @timestamp, @message
| filter @message like /duration:/
| sort @timestamp desc
| limit 20

# EKS API audit — who made which RBAC-sensitive calls
fields @timestamp, requestURI, user.username, verb
| filter @logStream like /audit/
  and verb in ["delete", "patch"]
| sort @timestamp desc
| limit 50
```

## Adding more notification channels

Subscribe Slack via webhook:
```bash
aws sns subscribe \
  --topic-arn $(terraform output -raw sns_alerts_topic_arn) \
  --protocol https \
  --notification-endpoint https://hooks.slack.com/services/YOUR/WEBHOOK
```

Subscribe PagerDuty:
1. PagerDuty UI → Services → New Integration → Amazon CloudWatch
2. Copy the integration URL
3. `aws sns subscribe --topic-arn ... --protocol https --notification-endpoint <url>`

Multi-channel routing without code: SNS topic fans out to all subscribers.

## Cost expectations

| Resource | Within free tier? |
|----------|------------------|
| Basic AWS metrics (RDS, EC2, NAT) | ✅ Free, forever |
| 5 alarms | ✅ 10 free |
| EKS control plane logs (~1 GB/month for a demo) | ✅ 5 GB free ingest |
| RDS Postgres logs (low volume demo) | ✅ Within free tier |
| RDS Performance Insights (7-day retention) | ✅ Free |
| RDS enhanced monitoring (60s interval) | ⚠️ ~$0.20/month per instance |
| SNS email notifications | ✅ 1000 free/month |
| **Demo total** | **~$0.20-0.50/month** |

## Interview line

> "CloudWatch handles AWS-managed service observability — EKS control plane
> logs (audit + API requests), RDS Postgres logs and Performance Insights
> for slow query analysis, and metrics for any AWS service that emits them
> by default. Application observability stays in Prometheus + Loki + Grafana.
> CloudWatch alarms watch infrastructure-level thresholds (RDS CPU/storage,
> NAT errors, node pressure) and route through SNS to email, Slack, or
> PagerDuty. The split — CloudWatch for AWS infra, Prometheus/Loki for apps —
> is the mainstream pattern at mid-size AWS shops; SaaS heavyweights like
> Datadog replace most of this in larger orgs that can afford the bill."

## Pattern summary

```
                  Inside cluster          AWS-managed
                  ──────────────          ───────────
Metrics:          Prometheus              CloudWatch (RDS, NAT, EBS)
Logs:             Fluent Bit → Loki       CloudWatch Logs (EKS, RDS)
View:             Grafana                 AWS Console (or Grafana via plugin)
Alerts:           AlertManager → SNS      CloudWatch alarms → SNS
Trigger:          App metric thresholds   AWS resource thresholds
Cost:             ~$3/month               ~$0.50/month
```
