#!/usr/bin/env bash
# Tear down the local kind developer stack.
#
# Usage:
#   ./scripts/dev-kind-down.sh [--keep-cluster] [--purge]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

KEEP_CLUSTER=false
PURGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-cluster) KEEP_CLUSTER=true; shift ;;
    --purge) PURGE=true; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

load_env
stop_port_forwards

if ! $KEEP_CLUSTER; then
  if command -v kind >/dev/null 2>&1; then
    log "deleting kind cluster $STRATA_KIND_CLUSTER"
    kind delete cluster --name "$STRATA_KIND_CLUSTER" || true
  fi
else
  log "leaving the kind cluster in place"
  kubectl delete namespace "$STRATA_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$STRATA_APP_PARTITION" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace authentik --ignore-not-found >/dev/null 2>&1 || true
fi

if $PURGE; then
  log "removing $STRATA_STATE_DIR (generated secrets and rendered manifests)"
  rm -rf "$STRATA_STATE_DIR"
else
  log "keeping $STRATA_STATE_DIR; pass --purge to remove generated secrets"
fi
