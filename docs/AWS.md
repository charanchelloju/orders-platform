# Running on AWS (EKS + RDS + Strimzi Kafka)

> ⚠️ **Cost reality check**: EKS control plane is **$0.10/hour (~$73/month)** — NOT in AWS Free Tier. Recommendation: spin up for a one-day demo (~$5), screenshot/record, tear down. Resume note: "Deployed and demoed on EKS."

## What gets created

- **VPC** with public + private subnets across 2 AZs
- **EKS cluster** (1.30, 3 × `t3.medium` worker nodes)
- **RDS Postgres** (`db.t3.micro` — free tier eligible)
- **ECR repositories** for all 4 services
- **IAM OIDC role** for GitHub Actions to deploy without long-lived keys
- **Strimzi Kafka operator** + **3-broker Kafka cluster (KRaft mode)** running in EKS

## Prerequisites

```bash
# Install:
aws --version          # AWS CLI v2
terraform --version    # >= 1.6
kubectl version        # >= 1.28
helm version           # >= 3.14

# Authenticate to AWS
aws configure          # access key, secret, region (ap-south-1)
```

## Step 1 — Provision infrastructure with Terraform

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set github_org, db_password

terraform init
terraform plan
terraform apply        # ~15 minutes to provision EKS
```

Note the outputs:
```
cluster_name         = "orders-platform-eks"
ecr_registry         = "123456789012.dkr.ecr.ap-south-1.amazonaws.com"
github_oidc_role_arn = "arn:aws:iam::...:role/orders-platform-github-actions"
rds_endpoint         = "orders-platform-postgres.xxx.rds.amazonaws.com:5432"
```

## Step 2 — Connect kubectl to the new EKS cluster

```bash
aws eks update-kubeconfig --name orders-platform-eks --region ap-south-1
kubectl get nodes      # should show 3 worker nodes Ready
```

## Step 3 — Install Strimzi operator + deploy Kafka cluster

```bash
# Install Strimzi operator
kubectl create namespace kafka
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Wait for operator to be ready
kubectl wait --for=condition=available --timeout=300s deployment/strimzi-cluster-operator -n kafka

# Deploy 3-broker Kafka cluster
kubectl apply -f infrastructure/kafka/kafka-cluster.yaml

# Wait for cluster ready (~5 min)
kubectl wait kafka/kafka-cluster --for=condition=Ready --timeout=600s -n kafka

# Create topics
kubectl apply -f infrastructure/kafka/topics.yaml

# Verify
kubectl get kafkatopics -n kafka
```

## Step 4 — Set up database schemas in RDS

```bash
# Connect through a temporary pod (RDS is in private subnets)
kubectl run psql-tmp --rm -it --image=postgres:16-alpine -- \
  psql "postgresql://postgres:YOUR_PASSWORD@RDS_ENDPOINT:5432/orders_platform"

# Inside psql, paste the contents of infrastructure/postgres/init.sql
```

## Step 5 — Create DB secrets in Kubernetes

```bash
# Replace placeholders before running
RDS_HOST="orders-platform-postgres.xxx.rds.amazonaws.com"

kubectl create namespace orders-platform

for svc in order payment inventory; do
  kubectl create secret generic ${svc}-service-db \
    --namespace orders-platform \
    --from-literal=SPRING_DATASOURCE_URL="jdbc:postgresql://${RDS_HOST}:5432/orders_platform?currentSchema=${svc}s" \
    --from-literal=SPRING_DATASOURCE_USERNAME="${svc}_service" \
    --from-literal=SPRING_DATASOURCE_PASSWORD="${svc}_pw"
done
```

(`inventory` schema is named `inventory`, not `inventorys` — adjust as needed.)

## Step 6 — Push images to ECR (via GitHub Actions)

Set GitHub repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value (from Terraform output) |
|----------|-------------------------------|
| `ECR_REGISTRY` | `123456789012.dkr.ecr.ap-south-1.amazonaws.com` |
| `AWS_OIDC_ROLE_ARN` | `arn:aws:iam::...:role/orders-platform-github-actions` |

Then push to `main` — the `ci.yml` workflow builds + pushes all 4 images.

## Step 7 — Deploy services via Helm

Use the GitHub Actions `deploy.yml` workflow (manually triggered), OR locally:

```bash
for svc in order-service payment-service inventory-service notification-service; do
  helm upgrade --install $svc ./helm/$svc \
    --namespace orders-platform \
    --create-namespace \
    --set image.repository=$ECR_REGISTRY/$svc \
    --set image.tag=latest \
    --set kafka.bootstrapServers=kafka-cluster-kafka-bootstrap.kafka:9092 \
    --wait
done
```

## Step 8 — Smoke test

```bash
# Port-forward order-service
kubectl port-forward -n orders-platform svc/order-service-order-service 8081:8081 &

# Create an order
curl -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"aws-test","productId":"keyboard","quantity":2}'

# Watch logs
kubectl logs -n orders-platform -l app.kubernetes.io/name=order-service -f
```

## Step 9 — Observe Kafka in the cluster

```bash
# Forward Kafka UI (if you deployed it as a Helm chart) OR exec into a broker pod
kubectl exec -n kafka -it kafka-cluster-broker-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list

kubectl exec -n kafka -it kafka-cluster-broker-0 -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-service
```

## Step 10 — Tear down (IMPORTANT — save cost)

```bash
# Remove Helm releases
helm uninstall order-service payment-service inventory-service notification-service \
  -n orders-platform

# Remove Strimzi resources
kubectl delete -f infrastructure/kafka/topics.yaml
kubectl delete -f infrastructure/kafka/kafka-cluster.yaml

# Destroy infrastructure
cd terraform/
terraform destroy
```

Verify in AWS Console: no EKS clusters, no RDS instances, no EC2 instances running.

## Total cost for a one-day demo

| Service | Hourly | 24-hour cost |
|---------|--------|--------------|
| EKS control plane | $0.10 | $2.40 |
| 3 × t3.medium nodes | 3 × $0.0416 | $3.00 |
| NAT Gateway | $0.045 + $0.045/GB | ~$1.10 |
| RDS db.t3.micro | (free tier) | $0 |
| ECR storage | (500MB free) | $0 |
| **Total** | | **~$6.50** |

Worth it for the screenshots and resume bullet point. **Don't forget `terraform destroy` at the end.**
