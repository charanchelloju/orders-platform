# ─── Logs: Fluent Bit (collector) → Loki (store) → Grafana (viewer) ───────
# The "logs" pillar of observability, complementing Prometheus (metrics).
#
# Fluent Bit:  DaemonSet on every node, tails /var/log/containers/*.log
#              enriches with K8s metadata, ships to Loki
# Loki:        Grafana's log database — cheap, label-based indexing
#              installed in monitoring namespace (same as Prometheus)
# Grafana:     already installed by monitoring.tf — Loki added as datasource

# ─── Loki ─────────────────────────────────────────────────────────────────
resource "helm_release" "loki" {
  name       = "loki"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.10.0"

  timeout       = 1200    # PVC binding via EBS CSI can be slow on first cluster
  wait_for_jobs = true
  atomic        = false   # don't auto-rollback so we can debug if it fails

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"      # simplest mode — fine for demo

      loki = {
        auth_enabled = false
        commonConfig = {
          replication_factor = 1
        }
        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "filesystem"
            schema       = "v13"
            index = {
              prefix = "index_"
              period = "24h"
            }
          }]
        }
        storage = {
          type = "filesystem"              # filesystem for demo; S3 for prod
        }
        # Disable analytics callback
        analytics = {
          reporting_enabled = false
        }
      }

      singleBinary = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        persistence = {
          enabled      = true
          size         = "10Gi"
          storageClass = "gp3"
        }
      }

      # Disable optional memcached caches — they require ~512Mi RAM each
      # which doesn't fit on our t3.small nodes after Prometheus/Grafana
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }

      # Disable components we don't need in SingleBinary mode
      backend       = { replicas = 0 }
      read          = { replicas = 0 }
      write         = { replicas = 0 }
      ingester      = { replicas = 0 }
      querier       = { replicas = 0 }
      queryFrontend = { replicas = 0 }
      queryScheduler = { replicas = 0 }
      distributor   = { replicas = 0 }
      compactor     = { replicas = 0 }
      indexGateway  = { replicas = 0 }

      # Tiny test mode to keep resource usage low (demo only)
      test = { enabled = false }
      lokiCanary = { enabled = false }

      # No gateway needed for demo
      gateway = { enabled = false }

      # MinIO not needed (filesystem storage)
      minio = { enabled = false }
    })
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ─── Fluent Bit ───────────────────────────────────────────────────────────
# DaemonSet — one pod per node. Tails /var/log/containers/*.log,
# enriches with K8s metadata, ships to Loki.
resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.47.10"

  timeout = 300

  values = [
    yamlencode({
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }

      # Custom config that ships to Loki instead of the default ES
      config = {
        # Inputs — what logs to read
        inputs = <<-EOT
          [INPUT]
              Name              tail
              Path              /var/log/containers/*.log
              multiline.parser  docker, cri
              Tag               kube.*
              Mem_Buf_Limit     5MB
              Skip_Long_Lines   On
              Refresh_Interval  10

          [INPUT]
              Name              systemd
              Tag               host.*
              Systemd_Filter    _SYSTEMD_UNIT=kubelet.service
              Read_From_Tail    On
        EOT

        # Filters — enrich with K8s metadata
        filters = <<-EOT
          [FILTER]
              Name                kubernetes
              Match               kube.*
              Merge_Log           On
              Keep_Log            Off
              K8S-Logging.Parser  On
              K8S-Logging.Exclude On
              Annotations         Off
              Labels              On
        EOT

        # Outputs — ship to Loki (SingleBinary service, port 3100 — gateway disabled)
        outputs = <<-EOT
          [OUTPUT]
              Name                   loki
              Match                  kube.*
              Host                   loki.monitoring.svc.cluster.local
              port                   3100
              labels                 job=fluent-bit, namespace=$kubernetes['namespace_name'], pod=$kubernetes['pod_name'], container=$kubernetes['container_name'], app=$kubernetes['labels']['app.kubernetes.io/name']
              line_format            json
              auto_kubernetes_labels off
        EOT

        # Custom parsers for various container log formats
        customParsers = <<-EOT
          [PARSER]
              Name        docker
              Format      json
              Time_Key    time
              Time_Format %Y-%m-%dT%H:%M:%S.%LZ
        EOT
      }

      # Loki output plugin is built-in; no extra installation needed
    })
  ]

  depends_on = [helm_release.loki]
}

output "loki_url" {
  value       = "http://loki.monitoring.svc.cluster.local:3100"
  description = "Loki endpoint used by Fluent Bit + Grafana (in-cluster only)"
}
