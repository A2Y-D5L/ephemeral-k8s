#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hack/util.sh"

PF_PID_FILE="${STATE_DIR}/kgateway-portforward.pid"

if [[ ! -f "${PF_PID_FILE}" ]]; then
  exit 0
fi

PID="$(cat "${PF_PID_FILE}" || true)"
if [[ -n "${PID}" ]] && kill -0 "${PID}" >/dev/null 2>&1; then
  log "Stopping kgateway port-forward (PID ${PID})"
  kill "${PID}" || true
fi

rm -f "${PF_PID_FILE}"