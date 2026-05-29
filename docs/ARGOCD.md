# ArgoCD — GitOps deployment

## What changed

`orders-platform` migrated from **push-based deploy** (CI runs `helm upgrade`) to
**pull-based GitOps** with ArgoCD.

```
   OLD (deploy.yml):                NEW (ArgoCD):
   CI ──helm upgrade──► EKS         CI ──git push──► gitops/applications/*
                                                    ArgoCD ──pull──► EKS
```

The previous workflow is preserved at
[.github/workflows/deploy.yml.example](../.github/workflows/deploy.yml.example)
for reference / fallback.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Developer pushes code change to main                                    │
│         │                                                                │
│         ▼                                                                │
│  GitHub Actions ci.yml:                                                  │
│    1. mvn verify                                                         │
│    2. docker build + push image:SHA to ECR                               │
│    3. yq -i bumps image.tag in gitops/applications/*.yaml                │
│    4. git commit + push to main  [skip ci]                               │
│                                                                          │
│         │  (CI's job is done)                                            │
│         ▼                                                                │
│  ArgoCD running in EKS (polls Git every ~3 min OR webhook):              │
│    1. Detects gitops/ changed                                            │
│    2. Renders Helm chart with new image tag                              │
│    3. Compares to live K8s state                                         │
│    4. Applies diff (rolling update)                                      │
│    5. Marks Application "Synced" + "Healthy"                             │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| [terraform/argocd.tf](../terraform/argocd.tf) | Installs ArgoCD via Helm into EKS; creates root Application |
| [gitops/applications/order-service.yaml](../gitops/applications/order-service.yaml) | ArgoCD Application pointing to `helm/order-service/` |
| [gitops/applications/payment-service.yaml](../gitops/applications/payment-service.yaml) | Same for payment-service |
| [gitops/applications/inventory-service.yaml](../gitops/applications/inventory-service.yaml) | Same for inventory-service |
| [gitops/applications/notification-service.yaml](../gitops/applications/notification-service.yaml) | Same for notification-service |
| [.github/workflows/ci.yml](../.github/workflows/ci.yml) | `bump-gitops` job updates image tags in gitops/ |

## One-time bootstrap

After `terraform apply` finishes:

```bash
# 1. ArgoCD is already installed by Terraform (helm_release.argocd)
# Verify:
kubectl get pods -n argocd

# 2. Fix placeholders in gitops/applications/*.yaml
# Replace these tokens with your real values:
#   REPLACE_GITHUB_ORG               → your-github-username
#   REPLACE_ECR_REGISTRY             → terraform output ecr_registry
#   REPLACE_<svc>_SERVICE_ROLE_ARN   → terraform output service_role_arns
# Then commit + push:
git add gitops/
git commit -m "configure ArgoCD applications with real ARNs"
git push

# 3. Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 4. Open the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Browse to http://localhost:8080
# Login: admin / <password from above>

# 5. The root app (orders-platform-root) auto-registers all 4 service Applications
# Watch them sync in the UI

# 6. Verify deployment
kubectl get applications -n argocd
kubectl get pods -n orders-platform
```

## Daily workflow

```bash
# Developer makes a code change
git push origin main

# Wait ~5 minutes:
#   ~3 min for CI to build images + push to ECR + bump gitops/
#   ~3 min for ArgoCD to detect Git change and sync (or instant with webhook)

# Verify in ArgoCD UI:
#   - Each Application shows "Synced" + "Healthy"
#   - Pods rolled to new image tag
```

## Rollback — easier than ever

```bash
# Option A: Git revert
git revert HEAD              # the "bump images to SHA xyz" commit
git push                     # ArgoCD reverts within minutes

# Option B: ArgoCD UI
# Click Application → History → previous revision → Rollback
```

## ArgoCD CLI (alternative to UI)

```bash
brew install argocd
argocd login localhost:8080 --username admin --password <pw> --insecure

argocd app list
argocd app sync order-service       # force immediate sync
argocd app history order-service
argocd app rollback order-service 5
```

## Webhook for instant sync (skip the 3-min poll)

For production speed, add a GitHub webhook:

```
GitHub repo → Settings → Webhooks → Add webhook
   Payload URL: https://argocd.your-domain.com/api/webhook
   Content type: application/json
   Events: Push
```

Now ArgoCD syncs within seconds of CI's push.

## What this gives you (interview talking points)

| Win | Detail |
|-----|--------|
| **Git = source of truth** | Cluster state always traces to a commit |
| **Drift detection** | `kubectl edit` is auto-reverted within minutes |
| **Visual dashboards** | See sync status, resource tree, health per app |
| **One-click rollback** | Git revert + push OR UI button |
| **No K8s creds in CI** | CI just pushes Git — ArgoCD has the cluster access |
| **Multi-cluster ready** | One ArgoCD can manage dev + staging + prod |
| **Sync waves** | Run DB migration BEFORE pod update via pre-sync hooks |
| **App-of-apps pattern** | One root Application registers all 4 services |

## Interview line

> "Deploys use GitOps via ArgoCD. CI builds images, pushes to ECR, then bumps
> the image tag in `gitops/applications/*.yaml` and commits to main. ArgoCD
> watches Git, detects the change, renders the Helm chart with the new tag,
> and applies a rolling update — all from inside the cluster. CI never holds
> cluster credentials. Drift is auto-reverted. Rollback is `git revert`.
> Same Helm charts as before — ArgoCD just consumes them instead of CI running
> `helm upgrade` directly."
