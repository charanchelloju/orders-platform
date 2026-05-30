# ─── ArgoCD installed into EKS via Helm ──────────────────────────────────
# ArgoCD watches the gitops/ folder in this repo and continuously syncs the
# cluster state to match. CI's job becomes "build image + bump tag in gitops/".

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "orders_platform" {
  metadata {
    name = "orders-platform"
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.6.0"

  values = [
    yamlencode({
      server = {
        service = { type = "ClusterIP" }
        config  = { "admin.enabled" = "true" }
      }

      configs = {
        params = {
          "server.insecure" = "true"

          # ALB sub-path routing: ArgoCD UI lives at <alb>/argocd
          # rootpath = where the server expects requests
          # basehref = prefix for UI static assets (must end with /)
          "server.rootpath" = "/argocd"
          "server.basehref" = "/argocd/"
        }
      }

      controller = { replicas = 1 }
      repoServer = { replicas = 1 }

      # The root "app of apps" is applied AFTER this release via the
      # separate helm_release.argocd_apps below — because the Application
      # CRD it references doesn't exist until ArgoCD has finished installing.
    })
  ]

  depends_on = [module.eks]
}

# ─── Root "app of apps" — installed AFTER ArgoCD CRDs are ready ──────────
# Uses a tiny custom Helm chart that only renders one Application manifest.
# We use a generic "raw" chart (bedag/raw) to avoid maintaining a chart of
# our own. Skipped CRD validation since Helm v3 will see the CRD by now.
resource "helm_release" "argocd_apps" {
  name       = "orders-platform-root-app"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://bedag.github.io/helm-charts/"
  chart      = "raw"
  version    = "2.0.0"

  values = [yamlencode({
    resources = [{
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata = {
        name      = "orders-platform-root"
        namespace = "argocd"
      }
      spec = {
        project = "default"
        source = {
          repoURL        = "https://github.com/${var.github_org}/${var.github_repo}.git"
          targetRevision = "main"
          path           = "gitops/applications"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }]
  })]

  depends_on = [helm_release.argocd]
}

output "argocd_admin_password_cmd" {
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  description = "Run this command to retrieve the ArgoCD admin password after install"
}

output "argocd_port_forward_cmd" {
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:80"
  description = "Then open http://localhost:8080 — login: admin / <password from above>"
}
