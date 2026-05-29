# Terraform Remote State — S3 + DynamoDB

## Why

Local `terraform.tfstate` works for solo demos but breaks the moment a second
person joins the project:

| Problem with local state | Solved by remote state |
|--------------------------|------------------------|
| State on one laptop — lost if drive dies | S3 with versioning, encrypted |
| Two devs `apply` at the same time → corruption | DynamoDB lock — only one at a time |
| No history of who changed what when | S3 object versioning |
| Plaintext file with secrets | S3 server-side encryption |

This is mandatory in any real team setup.

## Bootstrap (one-time)

S3 + DynamoDB must exist BEFORE Terraform can use them as backend. Create
them once via AWS CLI:

```powershell
$REGION     = "ap-south-1"
$PROJECT    = "orders-platform"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$BUCKET     = "$PROJECT-tfstate-$ACCOUNT_ID"

# S3 bucket
aws s3api create-bucket `
  --bucket $BUCKET --region $REGION `
  --create-bucket-configuration LocationConstraint=$REGION

aws s3api put-bucket-versioning `
  --bucket $BUCKET --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption `
  --bucket $BUCKET `
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'

aws s3api put-public-access-block `
  --bucket $BUCKET `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# DynamoDB lock table
aws dynamodb create-table `
  --table-name "$PROJECT-tflock" `
  --attribute-definitions AttributeName=LockID,AttributeType=S `
  --key-schema AttributeName=LockID,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST `
  --region $REGION
```

## Configure Terraform

In `terraform/versions.tf` the backend block references those resources:

```hcl
backend "s3" {
  bucket         = "orders-platform-tfstate-<YOUR_ACCOUNT_ID>"
  key            = "orders-platform/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "orders-platform-tflock"
  encrypt        = true
}
```

Replace `<YOUR_ACCOUNT_ID>` with your actual AWS account ID before running
`terraform init`.

## Migrate existing local state

If you already have `terraform.tfstate` locally:

```bash
cd terraform/
terraform init -migrate-state
# Type "yes" when asked to copy state to the new backend
```

Verify it landed in S3:
```bash
aws s3 ls "s3://orders-platform-tfstate-<ACCOUNT>/orders-platform/"
```

Then delete the local files:
```bash
rm terraform.tfstate terraform.tfstate.backup
```

## Daily workflow (no change)

```bash
terraform plan       # reads from S3, locks via DynamoDB
terraform apply      # writes back to S3 on completion
```

If someone else is running `apply`, you'll see:
```
Error: Error acquiring the state lock
```
Wait for them to finish.

## State versioning + recovery

S3 versioning saves every state revision. If you bork state:
```bash
# List versions
aws s3api list-object-versions \
  --bucket orders-platform-tfstate-<ACCOUNT> \
  --prefix orders-platform/terraform.tfstate

# Restore a previous version
aws s3api copy-object \
  --copy-source "orders-platform-tfstate-<ACCOUNT>/orders-platform/terraform.tfstate?versionId=<ID>" \
  --bucket orders-platform-tfstate-<ACCOUNT> \
  --key orders-platform/terraform.tfstate
```

## Multi-environment pattern (later)

For dev/staging/prod:
```hcl
# different key per env
backend "s3" {
  bucket = "orders-platform-tfstate-<ACCOUNT>"
  key    = "orders-platform/dev/terraform.tfstate"     # ← dev
  # ...
}
```

Or use Terraform workspaces:
```bash
terraform workspace new dev
terraform workspace new prod
# Each workspace gets its own state under env:/<workspace>/key in S3
```

## Cost

| Resource | Monthly cost (typical) |
|----------|------------------------|
| S3 storage (state files are small, ~MB) | < $0.01 |
| S3 PUT/GET requests | ~$0.01 |
| DynamoDB pay-per-request | < $0.10 |
| **Total** | **~$0.10/month** |

## Cleanup (when destroying everything)

```bash
# 1. Destroy Terraform-managed resources
terraform destroy

# 2. Tear down the state backend itself
aws s3 rm "s3://orders-platform-tfstate-<ACCOUNT>" --recursive
aws s3api delete-bucket --bucket "orders-platform-tfstate-<ACCOUNT>"
aws dynamodb delete-table --table-name orders-platform-tflock
```

## Interview line

> "Terraform state is stored remotely in an S3 bucket with versioning and
> server-side encryption, with locking via a DynamoDB table — standard pattern
> for any team setup. S3 + DynamoDB are created out-of-band (bootstrap script
> or separate Terraform workspace), then declared in the backend block. Local
> state never lives on developer laptops, two `terraform apply` calls can't
> race because DynamoDB locks, and S3 versioning gives full audit + recovery.
> Cost is under $0.10/month."
