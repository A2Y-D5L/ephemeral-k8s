#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT}/.state"
mkdir -p "${STATE_DIR}"

log() { printf "\n==> %s\n" "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

require_env() {
  local k="$1"
  if [[ -z "${!k:-}" || "${!k}" == "CHANGE_ME" ]]; then
    echo "Missing required env var: ${k}" >&2
    exit 1
  fi
}

wait_ns() {
  local ns="$1"
  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}" >/dev/null
}

wait_rollout() {
  local ns="$1" kind="$2" name="$3"
  kubectl -n "${ns}" rollout status "${kind}/${name}" --timeout=5m
}