#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

: "${CLUSTER_NAME:=ephem}"
: "${KGATEWAY_VERSION:=v2.1.2}"
: "${GATEWAY_API_VERSION:=v1.4.0}"
: "${GIT_REPO_URL:=CHANGE_ME}"
: "${GIT_REVISION:=main}"

require_env GIT_REPO_URL
require_env GIT_REVISION

log "Checking prerequisites"
need docker
need kind
need kubectl
need helm
need mkcert
need yq

log "Verifying Docker Desktop is running"
docker info >/dev/null

log "Recreating kind cluster: ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT}/kind.yaml"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

log "Installing Gateway API CRDs (${GATEWAY_API_VERSION} standard)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null

log "Installing kgateway CRDs (Helm OCI) ${KGATEWAY_VERSION}"
helm upgrade -i kgateway-crds \
  "oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds" \
  --create-namespace --namespace kgateway-system \
  --version "${KGATEWAY_VERSION}" >/dev/null

log "Installing kgateway (Helm OCI) ${KGATEWAY_VERSION}"
helm upgrade -i kgateway \
  "oci://cr.kgateway.dev/kgateway-dev/charts/kgateway" \
  --namespace kgateway-system \
  --version "${KGATEWAY_VERSION}" >/dev/null

log "Waiting for kgateway workloads"
# Wait for Deployments/StatefulSets if present; then ensure pods are Ready.
kubectl -n kgateway-system wait --for=condition=Available deploy --all --timeout=5m >/dev/null 2>&1 || true
kubectl -n kgateway-system wait --for=condition=Ready pod --all --timeout=5m >/dev/null

log "Ensuring namespaces"
wait_ns argocd

log "Generating local TLS cert (*.localhost) with mkcert"
CERT_DIR="${STATE_DIR}/certs"
mkdir -p "${CERT_DIR}"
mkcert \
  -key-file "${CERT_DIR}/tls.key" \
  -cert-file "${CERT_DIR}/tls.crt" \
  "*.localhost" localhost >/dev/null

log "Creating TLS secret for kgateway"
kubectl -n kgateway-system delete secret localhost-wildcard >/dev/null 2>&1 || true
kubectl -n kgateway-system create secret tls localhost-wildcard \
  --key "${CERT_DIR}/tls.key" \
  --cert "${CERT_DIR}/tls.crt" >/dev/null

log "Applying kgateway Gateway (edge)"
kubectl apply -f "${ROOT}/manifests/edge-gateway.yaml" >/dev/null

log "Waiting for Gateway to be programmed"
kubectl -n kgateway-system wait --for=condition=Programmed gateway/edge --timeout=2m >/dev/null

log "Installing Argo CD via Helm (Dex config lives in argocd-cm)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

helm upgrade -i argocd argo/argo-cd \
  -n argocd \
  -f "${ROOT}/helm/argocd-values.yaml" >/dev/null

log "Waiting for Argo CD pods"
kubectl -n argocd wait --for=condition=Ready pod --all --timeout=5m >/dev/null

log "Applying HTTPRoutes (Argo CD + app UIs)"
kubectl apply -f "${ROOT}/manifests/routes.yaml" >/dev/null

log "Bootstrapping root app-of-apps Application"
ROOT_APP_RENDERED="${STATE_DIR}/root-app.yaml"
cat > "${ROOT_APP_RENDERED}" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_REVISION}
    path: gitops/applications
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f "${ROOT_APP_RENDERED}" >/dev/null

log "Starting kgateway port-forward"
"${ROOT}/hack/portforward-start.sh" >/dev/null

PASS="$(
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
)"

cat <<EOF

✅ Cluster is up, Argo CD is installed, and root app-of-apps has been applied.
Argo CD should begin syncing child apps automatically.

URLs:
- Argo CD:  https://argocd.localhost:8443
- LLDAP UI: https://lldap.localhost:8443  (once Argo syncs it)

Argo CD initial admin password:
${PASS}

To delete everything:
- make down

EOF