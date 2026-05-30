# ─── Monitoring stack: Prometheus + Grafana + AlertManager ────────────────
# Uses the industry-standard kube-prometheus-stack chart which bundles:
#   - Prometheus Operator + CRDs (ServiceMonitor, PodMonitor, PrometheusRule)
#   - Prometheus server (with persistent storage)
#   - AlertManager (route alerts to Slack/PagerDuty)
#   - Grafana with pre-loaded dashboards
#   - kube-state-metrics (Kubernetes object metrics)
#   - node-exporter (host-level metrics)
#
# Spring Boot services expose metrics at /actuator/prometheus.
# Each service's Helm chart includes a ServiceMonitor (see helm/*/templates/
# servicemonitor.yaml) telling Prometheus to scrape it.

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "61.3.0"

  # ~10 min install — many CRDs and components
  timeout = 900

  values = [
    yamlencode({
      # ─── Prometheus tuning ─────────────────────────────────────────
      prometheus = {
        prometheusSpec = {
          retention     = "15d"
          retentionSize = "18GiB"

          # ALB sub-path routing: Prometheus is served at <alb>/prometheus.
          # AlertManager requires a fully-qualified externalUrl with scheme
          # (path-only fails with "invalid scheme"); Prometheus follows suit
          # for consistency. ALB DNS is captured here for now; once Route 53
          # + a custom domain are wired up, replace with api.<domain>.
          externalUrl = "http://k8s-ordersplatform-e8323cc06c-1834496908.ap-south-1.elb.amazonaws.com/prometheus"
          routePrefix = "/prometheus"

          resources = {
            requests = { memory = "1Gi", cpu = "250m" }
            limits   = { memory = "2Gi", cpu = "1000m" }
          }

          # Pick up ALL ServiceMonitors in the cluster (not just helm-labelled ones)
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false

          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = "gp3"
                resources = {
                  requests = { storage = "20Gi" }
                }
              }
            }
          }
        }
        service = { type = "ClusterIP" }
      }

      # ─── Grafana ──────────────────────────────────────────────────
      grafana = {
        enabled       = true
        adminPassword = "admin" # demo only — use Secrets Manager in prod
        service       = { type = "ClusterIP" }

        # ALB sub-path routing: Grafana lives at <alb>/grafana.
        # %(protocol)s and %(domain)s are Grafana's own interpolation
        # variables — domain is auto-discovered from the Host header,
        # so we don't have to hard-code the ALB DNS.
        "grafana.ini" = {
          server = {
            root_url            = "%(protocol)s://%(domain)s/grafana"
            serve_from_sub_path = true
          }
        }

        # Additional datasources: Loki for logs (Prometheus is auto-added)
        additionalDataSources = [{
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          url       = "http://loki.monitoring.svc.cluster.local:3100"
          access    = "proxy"
          isDefault = false
          jsonData = {
            maxLines       = 1000
            timeout        = 60
            derivedFields  = []
          }
        }]

        # Pre-load community dashboards (no JSON to maintain)
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [{
              name            = "default"
              orgId           = 1
              folder          = ""
              type            = "file"
              disableDeletion = false
              editable        = true
              options         = { path = "/var/lib/grafana/dashboards/default" }
            }]
          }
        }

        dashboards = {
          default = {
            jvm-micrometer = {                   # JVM + Micrometer (community 4701)
              gnetId     = 4701
              revision   = 9
              datasource = "Prometheus"
            }
            spring-boot = {                       # Spring Boot HTTP stats (6756)
              gnetId     = 6756
              revision   = 1
              datasource = "Prometheus"
            }
            strimzi-kafka = {                     # Strimzi Kafka cluster (11762)
              gnetId     = 11762
              revision   = 1
              datasource = "Prometheus"
            }
            strimzi-kafka-exporter = {            # Consumer lag (11285)
              gnetId     = 11285
              revision   = 1
              datasource = "Prometheus"
            }
            loki-k8s-logs = {                     # Logs/Apps explorer (15141)
              gnetId     = 15141
              revision   = 1
              datasource = "Loki"
            }
          }
        }
      }

      # ─── AlertManager ─────────────────────────────────────────────
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          # ALB sub-path routing: AlertManager lives at <alb>/alertmanager.
          # externalUrl MUST be a full http(s) URL — AlertManager rejects
          # path-only values at startup.
          externalUrl = "http://k8s-ordersplatform-e8323cc06c-1834496908.ap-south-1.elb.amazonaws.com/alertmanager"
          routePrefix = "/alertmanager"

          resources = {
            requests = { memory = "100Mi", cpu = "50m" }
            limits   = { memory = "200Mi", cpu = "200m" }
          }
        }
      }

      # ─── Cluster-level metrics ────────────────────────────────────
      nodeExporter     = { enabled = true }
      kubeStateMetrics = { enabled = true }
      defaultRules     = { create = true }
    })
  ]

  depends_on = [module.eks]
}

output "grafana_port_forward_cmd" {
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
  description = "Then open http://localhost:3000 — login: admin / admin"
}

output "prometheus_port_forward_cmd" {
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
  description = "Then open http://localhost:9090 for Prometheus UI"
}

output "alertmanager_port_forward_cmd" {
  value       = "kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093"
  description = "Then open http://localhost:9093 for AlertManager UI"
}
