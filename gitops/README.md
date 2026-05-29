# GitOps manifests

This folder is the **single source of truth** for what's deployed in EKS.
ArgoCD watches `gitops/applications/` and continuously syncs the cluster.

## Files

- `applications/order-service.yaml` — ArgoCD Application for order-service
- `applications/payment-service.yaml`
- `applications/inventory-service.yaml`
- `applications/notification-service.yaml`

Each Application points to a Helm chart in `helm/<service>/` and sets the
image tag. CI bumps the image tag here when new images are pushed to ECR.

## Why

- **Git = source of truth**: anything deployed traces back to a commit
- **Rollback** = `git revert` + push
- **Audit** = `git log gitops/`
- **Drift detection**: if someone `kubectl edit`s a Deployment, ArgoCD reverts it
- **CI doesn't need cluster credentials** — it just pushes to Git
