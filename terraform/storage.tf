# ─── Default storage class: gp3 ───────────────────────────────────────────
# By default EKS only ships with the gp2 class, but our Helm releases
# (Prometheus, Loki, Kafka brokers, RDS-less workloads) reference gp3 which
# is faster + cheaper. We create it explicitly and mark it default.

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [module.eks]
}

# Remove the "default" annotation from gp2 so gp3 is the sole default
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true

  depends_on = [module.eks]
}
