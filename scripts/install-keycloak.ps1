# Install / re-install Keycloak in the cluster.
#
# Pre-requisites (handled by Terraform):
#   - keycloak namespace exists
#   - K8s Secret 'keycloak-admin' exists in that namespace (synced by ESO
#     from AWS Secrets Manager: orders-platform/keycloak/admin)
#   - ALB Controller installed (so the keycloak-ingress can provision listener rules)
#
# Why this script and not Terraform helm_release?
#   The Bitnami Keycloak chart referenced a Postgres image tag removed
#   from Docker Hub. Until upstream is fixed (or we move to codecentric/
#   keycloakx), the official Keycloak image is applied as a raw manifest.
#
# Usage:
#   .\scripts\install-keycloak.ps1

$ErrorActionPreference = "Stop"

$ALB_DNS = "k8s-ordersplatform-e8323cc06c-1834496908.ap-south-1.elb.amazonaws.com"

# Ensure the namespace + admin secret exist (Terraform should have done this)
kubectl get namespace keycloak | Out-Null
kubectl get secret -n keycloak keycloak-admin | Out-Null
Write-Host "[ok] namespace + keycloak-admin secret in place"

$manifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:24.0
          args: ["start-dev"]
          env:
            - name: KEYCLOAK_ADMIN
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: admin-user
            - name: KEYCLOAK_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: admin-password
            - name: KC_HTTP_RELATIVE_PATH
              value: "/auth"
            - name: KC_HOSTNAME
              value: "$ALB_DNS"
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_HOSTNAME_STRICT_HTTPS
              value: "false"
            - name: KC_PROXY
              value: "edge"
            - name: KC_HTTP_ENABLED
              value: "true"
            - name: JAVA_OPTS_KC_HEAP
              value: "-Xms256m -Xmx512m"
          ports:
            - containerPort: 8080
              name: http
          startupProbe:
            httpGet:
              path: /auth/realms/master
              port: 8080
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /auth/realms/master
              port: 8080
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /auth/realms/master
              port: 8080
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: 1000m
              memory: 768Mi
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  type: ClusterIP
  selector:
    app: keycloak
  ports:
    - port: 80
      targetPort: 8080
      name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-ingress
  namespace: keycloak
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /auth/realms/master
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
    alb.ingress.kubernetes.io/group.name: orders-platform
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /auth
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 80
"@

$manifest | kubectl apply -f -
Write-Host "[ok] Keycloak Deployment + Service + Ingress applied"

Write-Host ""
Write-Host "Wait for the pod to become Ready (90-120 seconds):"
Write-Host "  kubectl get pod -n keycloak -w"
Write-Host ""
Write-Host "Then run scripts/keycloak-setup.ps1 to bootstrap the realm."
