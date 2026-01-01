#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

PF_PID_FILE="${STATE_DIR}/kgateway-portforward.pid"
LOG_FILE="${STATE_DIR}/kgateway-portforward.log"

log "Starting kgateway port-forward (background)"

DEPLOY="$(
  kubectl -n kgateway-system get deploy \
    -l gateway.networking.k8s.io/gateway-name=edge \
    -o jsonpath='{.items[0].metadata.name}'
)"

if [[ -z "${DEPLOY}" ]]; then
  echo "Could not find kgateway proxy deployment for Gateway 'edge'." >&2
  exit 1
fi

if [[ -f "${PF_PID_FILE}" ]]; then
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portforward-stop.sh" || true
fi

nohup kubectl -n kgateway-system port-forward "deploy/${DEPLOY}" 8443:8443 >"${LOG_FILE}" 2>&1 &
echo $! >"${PF_PID_FILE}"

log "Port-forward running (PID $(cat "${PF_PID_FILE}"))"