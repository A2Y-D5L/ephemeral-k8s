#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

: "${CLUSTER_NAME:=ephem}"
: "${KGATEWAY_VERSION:=v2.1.2}"
: "${GATEWAY_API_VERSION:=v1.4.0}"
: "${GIT_REPO_URL:=CHANGE_ME}"
: "${GIT_REVISION:=main}"
: "${PERSIST_LLDAP:=0}"
: "${PERSIST_ROOT:=${ROOT}/.persist}"
: "${PERSIST_DIR:=${PERSIST_ROOT}/lldap}"

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

# --- Persistence setup ---
KIND_CONFIG="${ROOT}/kind.yaml"

if [[ "${PERSIST_LLDAP}" == "1" ]]; then
  log "Persistence enabled: setting up ${PERSIST_DIR}"
  mkdir -p "${PERSIST_DIR}"
  chmod 777 "${PERSIST_DIR}"

  # Generate kind config with extraMounts for all nodes
  KIND_CONFIG="${STATE_DIR}/kind.yaml"
  log "Generating kind config with extraMounts"
  cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${PERSIST_DIR}
        containerPath: /var/local-path/lldap
  - role: worker
    extraMounts:
      - hostPath: ${PERSIST_DIR}
        containerPath: /var/local-path/lldap
  - role: worker
    extraMounts:
      - hostPath: ${PERSIST_DIR}
        containerPath: /var/local-path/lldap
EOF
fi

log "Recreating kind cluster: ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# --- Apply PV early if persistence is enabled ---
if [[ "${PERSIST_LLDAP}" == "1" ]]; then
  log "Creating PersistentVolume for LLDAP"
  cat > "${STATE_DIR}/lldap-pv.yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: lldap-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lldap-hostpath
  hostPath:
    path: /var/local-path/lldap
    type: DirectoryOrCreate
EOF
  kubectl apply -f "${STATE_DIR}/lldap-pv.yaml" >/dev/null
fi

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
# Wait for Deployments to be Available (more robust than waiting for all pods,
# which can fail if any Job pods exist in a Completed state).
kubectl -n kgateway-system wait --for=condition=Available deploy --all --timeout=5m >/dev/null

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
# Wait for Deployments and StatefulSets to be ready.
# Note: We avoid `kubectl wait pod --all` because Helm hook Jobs (e.g.,
# argocd-redis-secret-init) create pods that complete and are not "Ready",
# causing the wait to fail.
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=5m >/dev/null
kubectl -n argocd wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset --all --timeout=5m >/dev/null

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

# --- Persistence: wait for LLDAP namespace and apply PVC + patch deployment ---
if [[ "${PERSIST_LLDAP}" == "1" ]]; then
  log "Waiting for LLDAP namespace to be created by Argo CD"
  for _ in {1..60}; do
    if kubectl get ns lldap >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl get ns lldap >/dev/null 2>&1; then
    echo "ERROR: lldap namespace was not created within timeout" >&2
    exit 1
  fi

  log "Creating PersistentVolumeClaim for LLDAP"
  cat > "${STATE_DIR}/lldap-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lldap-pvc
  namespace: lldap
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: lldap-hostpath
  resources:
    requests:
      storage: 1Gi
  volumeName: lldap-pv
EOF
  kubectl apply -f "${STATE_DIR}/lldap-pvc.yaml" >/dev/null

  log "Waiting for LLDAP deployment to be synced by Argo CD"
  for _ in {1..60}; do
    if kubectl -n lldap get deploy lldap >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n lldap get deploy lldap >/dev/null 2>&1; then
    echo "ERROR: lldap deployment was not created within timeout" >&2
    exit 1
  fi

  log "Waiting for LLDAP Argo CD Application to exist"
  for _ in {1..30}; do
    if kubectl -n argocd get app lldap >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n argocd get app lldap >/dev/null 2>&1; then
    echo "ERROR: lldap Application was not created within timeout" >&2
    exit 1
  fi

  log "Configuring Argo CD to ignore volume differences for LLDAP"
  # Patch the Argo CD Application to ignore the volume field, preventing selfHeal
  # from reverting our deployment patch
  kubectl -n argocd patch app lldap --type=merge -p '{
    "spec": {
      "ignoreDifferences": [
        {
          "group": "apps",
          "kind": "Deployment",
          "name": "lldap",
          "namespace": "lldap",
          "jsonPointers": ["/spec/template/spec/volumes"]
        }
      ]
    }
  }' >/dev/null

  log "Patching LLDAP deployment to use PVC"
  kubectl -n lldap patch deploy lldap --type=json -p '[
    {"op": "replace", "path": "/spec/template/spec/volumes/0", "value": {"name": "data", "persistentVolumeClaim": {"claimName": "lldap-pvc"}}}
  ]' >/dev/null

  log "Waiting for LLDAP pod to be ready with persistent storage"
  kubectl -n lldap rollout status deploy/lldap --timeout=2m >/dev/null
fi

log "Starting kgateway port-forward"
"${ROOT}/hack/portforward-start.sh" >/dev/null

PASS="$(
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
)"

PERSIST_MSG=""
if [[ "${PERSIST_LLDAP}" == "1" ]]; then
  PERSIST_MSG="
LLDAP persistence: ENABLED
  Data stored in: ${PERSIST_DIR}
  To reset: make clean
"
fi

cat <<EOF

✅ Cluster is up, Argo CD is installed, and root app-of-apps has been applied.
Argo CD should begin syncing child apps automatically.
${PERSIST_MSG}
URLs:
- Argo CD:  https://argocd.localhost:8443
- LLDAP UI: https://lldap.localhost:8443  (once Argo syncs it)

Argo CD initial admin password:
${PASS}

To delete everything:
- make down

EOF