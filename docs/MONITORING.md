# Monitoring — Prometheus + Grafana + AlertManager

## What you get

```
┌────────────────────────────────────────────────────────────────────┐
│  Prometheus      ← scrapes metrics every 30s from:                 │
│                     • Spring Boot services (/actuator/prometheus)   │
│                     • Kafka brokers (JMX → Prometheus)              │
│                     • Kafka Exporter (consumer lag)                 │
│                     • kube-state-metrics (K8s objects)              │
│                     • node-exporter (host CPU/mem/disk)             │
│  Grafana         ← visualizes Prometheus data                       │
│                     pre-loaded dashboards: JVM, Spring Boot, Kafka  │
│  AlertManager    ← routes alerts to Slack / PagerDuty               │
└────────────────────────────────────────────────────────────────────┘
```

## Files added

| File | Purpose |
|------|---------|
| [terraform/monitoring.tf](../terraform/monitoring.tf) | Installs kube-prometheus-stack via Helm |
| [helm/*/templates/servicemonitor.yaml](../helm/) | Tells Prometheus to scrape each Spring Boot service |
| [helm/*/values.yaml](../helm/) | New `serviceMonitor.enabled` block |
| [infrastructure/kafka/kafka-cluster.yaml](../infrastructure/kafka/kafka-cluster.yaml) | Added `metricsConfig` + `kafkaExporter` |
| [infrastructure/kafka/kafka-metrics-configmap.yaml](../infrastructure/kafka/kafka-metrics-configmap.yaml) | JMX → Prometheus rule mappings |
| [infrastructure/kafka/kafka-podmonitor.yaml](../infrastructure/kafka/kafka-podmonitor.yaml) | PodMonitors for Strimzi pods |

## Bootstrap

After `terraform apply`:

```bash
# 1. kube-prometheus-stack is already installed by Terraform
kubectl get pods -n monitoring

# 2. Apply Kafka metrics config BEFORE the Kafka cluster (re)deploy
kubectl apply -f infrastructure/kafka/kafka-metrics-configmap.yaml

# 3. (Re-)apply Kafka cluster — now with metricsConfig + kafkaExporter
kubectl apply -f infrastructure/kafka/kafka-cluster.yaml

# 4. Apply PodMonitors so Prometheus scrapes Kafka pods
kubectl apply -f infrastructure/kafka/kafka-podmonitor.yaml

# 5. Verify Prometheus targets — should see all 4 services + Kafka + Kafka Exporter
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
# Browse http://localhost:9090/targets — everything should be "UP"
```

## Open Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Browse http://localhost:3000
# Login: admin / admin (demo only — change in production)
```

## Pre-loaded dashboards

| Dashboard | What it shows |
|-----------|---------------|
| **JVM (Micrometer)** | Heap, GC pause times, threads, classes loaded — per service |
| **Spring Boot HTTP** | Request rate, latency p99, error rate — per endpoint |
| **Strimzi Kafka** | Broker health, partition leaders, ISR, controller status |
| **Strimzi Kafka Exporter** | **Consumer lag per group per partition** — the #1 metric |
| **Kubernetes / Compute / Pods** | CPU + memory per pod across all namespaces |
| **Kubernetes / Compute / Nodes** | Node CPU + memory + disk pressure |
| **AlertManager** | Active alerts |

## What's being measured

### Per-service (Spring Boot, via Micrometer)
- `http_server_requests_seconds_count` — request rate
- `http_server_requests_seconds_max` — max latency
- `http_server_requests_seconds_bucket` — latency histogram (for p99 calc)
- `jvm_memory_used_bytes` — heap usage
- `jvm_gc_pause_seconds_*` — GC pause durations
- `kafka_consumer_records_lag_max` — per-consumer lag (when using Spring Kafka)
- `process_cpu_usage` — CPU per pod

### Per Kafka cluster
- `kafka_server_replicamanager_underreplicatedpartitions` — health red flag
- `kafka_controller_kafkacontroller_activecontrollercount` — exactly 1 expected
- `kafka_server_brokertopicmetrics_*` — bytes in/out, msg rate per topic
- `kafka_consumergroup_lag` — lag per (group, topic, partition) — from Kafka Exporter
- `kafka_topic_partition_under_replicated_partition` — broken replicas

### Cluster
- `node_cpu_seconds_total`, `node_memory_*` — node resource pressure
- `kube_pod_status_phase` — pod state counts
- `kube_pod_container_status_restarts_total` — pod restart counter

## Useful queries

Try in Prometheus UI (http://localhost:9090):

```promql
# Total request rate per service
sum by (application) (rate(http_server_requests_seconds_count[5m]))

# p99 latency per endpoint
histogram_quantile(0.99, sum by (uri, le) (
  rate(http_server_requests_seconds_bucket[5m])
))

# Error rate per service
sum by (application) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
/ sum by (application) (rate(http_server_requests_seconds_count[5m]))

# Consumer lag per group
sum by (consumergroup, topic) (kafka_consumergroup_lag)

# JVM heap usage % per pod
jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}
```

## Adding alerts

Create a `PrometheusRule` resource — kube-prometheus-stack picks it up automatically:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: orders-platform-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: orders-platform
      rules:
        - alert: HighConsumerLag
          expr: kafka_consumergroup_lag > 5000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Consumer group {{ $labels.consumergroup }} is lagging"
            description: "Lag is {{ $value }} on topic {{ $labels.topic }}"

        - alert: HighErrorRate
          expr: |
            (sum by (application) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
             / sum by (application) (rate(http_server_requests_seconds_count[5m]))) > 0.01
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "{{ $labels.application }} error rate > 1%"

        - alert: PodCrashLoop
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} in crashloop"
```

## Routing alerts to Slack/PagerDuty

Edit AlertManager config (in `terraform/monitoring.tf` values):

```yaml
alertmanager:
  config:
    route:
      receiver: 'pagerduty-critical'
      routes:
        - matchers: [severity = "critical"]
          receiver: 'pagerduty-critical'
        - matchers: [severity = "warning"]
          receiver: 'slack-warnings'
    receivers:
      - name: 'pagerduty-critical'
        pagerduty_configs:
          - service_key: 'YOUR_PAGERDUTY_INTEGRATION_KEY'
      - name: 'slack-warnings'
        slack_configs:
          - api_url: 'YOUR_SLACK_WEBHOOK_URL'
            channel: '#alerts'
```

## Cost impact

| Resource | Cost |
|----------|------|
| Prometheus EBS volume (20Gi gp3) | ~$2/month |
| Grafana EBS volume (10Gi gp3) | ~$1/month |
| Extra cluster RAM (~2Gi total) | Fits in existing nodes |
| Total | **~$3/month added** |

## Interview line

> "Observability uses kube-prometheus-stack — Prometheus, Grafana, AlertManager
> bundled. Spring Boot services expose `/actuator/prometheus`; ServiceMonitors
> per Helm chart tell Prometheus to scrape them. Strimzi exposes Kafka JMX via
> a Prometheus exporter and runs Kafka Exporter for per-group consumer lag,
> the #1 Kafka operational metric. Grafana pre-loads community dashboards for
> JVM, Spring Boot HTTP, and Kafka. AlertManager routes critical thresholds
> to PagerDuty and warnings to Slack via PrometheusRule resources. Without
> this stack you find out about outages from customer complaints; with it
> you find out within minutes."

## Future enhancements (not implemented)

- **Loki** for log aggregation (Grafana panel correlates logs ↔ metrics)
- **Tempo / Jaeger** for distributed tracing (W3C trace headers in Kafka)
- **OpenTelemetry Collector** instead of direct Prometheus scraping
- **Thanos** for long-term metric retention (>15d) + cross-cluster querying
- **Datadog / NewRelic** as SaaS alternative — skips most of this setup but $$
