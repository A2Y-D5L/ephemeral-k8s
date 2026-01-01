#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

: "${CLUSTER_NAME:=ephem}"

log "Stopping background port-forwards (if any)"
# Idempotent: does nothing if no PID file exists.
"${ROOT}/hack/portforward-stop.sh" || true

log "Deleting kind cluster: ${CLUSTER_NAME}"
# kind is intentionally idempotent: deleting a non-existent cluster is not an error.
kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true

log "Cleaning local state"
rm -rf "${STATE_DIR}"

log "Done"