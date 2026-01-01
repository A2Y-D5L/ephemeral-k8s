#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

PF_PID_FILE="${STATE_DIR}/kgateway-portforward.pid"
LOG_FILE="${STATE_DIR}/kgateway-portforward.log"

log "Starting kgateway port-forward (background)"

log "Waiting for kgateway proxy deployment"
DEPLOY=""
for _ in {1..30}; do
  DEPLOY="$(kubectl -n kgateway-system get deploy \
    -l gateway.networking.k8s.io/gateway-name=edge \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" && [[ -n "${DEPLOY}" ]] && break
  sleep 2
done

if [[ -z "${DEPLOY}" ]]; then
  echo "Could not find kgateway proxy deployment for Gateway 'edge'." >&2
  echo "Expected label: gateway.networking.k8s.io/gateway-name=edge" >&2
  exit 1
fi

if [[ -f "${PF_PID_FILE}" ]]; then
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portforward-stop.sh" || true
fi

nohup kubectl -n kgateway-system port-forward "deploy/${DEPLOY}" 8443:8443 >"${LOG_FILE}" 2>&1 &
echo $! >"${PF_PID_FILE}"

log "Port-forward running (PID $(cat "${PF_PID_FILE}"))"

# Give port-forward a moment to start, then verify it's working
sleep 2
if ! kill -0 "$(cat "${PF_PID_FILE}")" 2>/dev/null; then
  log "Warning: port-forward process exited unexpectedly. Check ${LOG_FILE}"
elif ! curl -ksf --connect-timeout 2 https://localhost:8443 >/dev/null 2>&1; then
  log "Warning: port-forward may not be working (could not connect to https://localhost:8443)"
fi