#!/usr/bin/env bash
# Remove the Strata control plane from the current Kubernetes cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=true; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

load_env
if ! $YES; then
  printf 'Delete namespaces %s and %s from the current cluster? [y/N] ' "$STRATA_NAMESPACE" "$STRATA_APP_PARTITION"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 0
fi

stop_port_forwards
kubectl delete namespace "$STRATA_NAMESPACE" --ignore-not-found
kubectl delete namespace "$STRATA_APP_PARTITION" --ignore-not-found
log "removed Strata namespaces"
