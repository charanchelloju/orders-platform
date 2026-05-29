#!/usr/bin/env bash
# Install External Secrets Operator into EKS — one-time setup.
# Run after `terraform apply` and `aws eks update-kubeconfig`.

set -euo pipefail

# 1. Install ESO via Helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true \
  --wait

# 2. Annotate its ServiceAccount with the ESO IRSA role
# Replace ARN with output from `terraform output eso_role_arn` (you'll add this).
ESO_ROLE_ARN="${ESO_ROLE_ARN:-arn:aws:iam::ACCOUNT_ID:role/PROJECT-eso}"

kubectl annotate serviceaccount external-secrets-sa \
  -n external-secrets \
  eks.amazonaws.com/role-arn="$ESO_ROLE_ARN" \
  --overwrite

# 3. Apply the ClusterSecretStore
kubectl apply -f infrastructure/eso/cluster-secret-store.yaml

# 4. Verify
kubectl get clustersecretstores
echo "✓ ESO installed. Now: helm upgrade --install order-service ./helm/order-service"
