#!/usr/bin/env bash
# Spin up the public Strata developer stack on a local kind cluster.
#
# Usage:
#   ./scripts/dev-kind-up.sh [--skip-build] [--no-port-forward] [--reset]
#
# The script builds MonoFS, Guardian, and Doctor from the sibling checkouts,
# loads them into kind, starts the control plane, and onboards the example
# application partition.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

SKIP_BUILD=false
NO_PORT_FORWARD=false
RESET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --no-port-forward) NO_PORT_FORWARD=true; shift ;;
    --reset) RESET=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

require docker "install Docker"
require kind "install kind"
require kubectl "install kubectl"
require go "install Go 1.26+"
require openssl "install OpenSSL"
require curl "install curl"

ensure_siblings
require_siblings
ensure_secrets

if $RESET; then
  log "deleting existing kind cluster $STRATA_KIND_CLUSTER"
  kind delete cluster --name "$STRATA_KIND_CLUSTER" >/dev/null 2>&1 || true
fi

if ! kind get clusters 2>/dev/null | grep -qx "$STRATA_KIND_CLUSTER"; then
  log "creating kind cluster $STRATA_KIND_CLUSTER"
  kind create cluster --name "$STRATA_KIND_CLUSTER" --config "$ROOT/bootstrap/kind/cluster.yaml"
else
  log "using existing kind cluster $STRATA_KIND_CLUSTER"
fi
kubectl config use-context "kind-$STRATA_KIND_CLUSTER" >/dev/null

if ! $SKIP_BUILD; then
  log "building MonoFS images"
  docker build --target router -t "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target server -t "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target fetcher -t "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" "$ROOT/../monofs"

  log "building Guardian images"
  DOCKER_BUILDKIT=1 docker build \
    --build-context "monofs=$ROOT/../monofs" \
    --build-context "kvs=$ROOT/../kvs" \
    -t "$STRATA_IMAGE_PREFIX/guardiand:$STRATA_IMAGE_TAG" \
    "$ROOT/../guardian"
  DOCKER_BUILDKIT=1 docker build \
    --build-context "monofs=$ROOT/../monofs" \
    --build-context "kvs=$ROOT/../kvs" \
    -f "$ROOT/../guardian/Dockerfile.pusher-k8s" \
    -t "$STRATA_IMAGE_PREFIX/guardian-pusher-k8s:$STRATA_IMAGE_TAG" \
    "$ROOT/../guardian"

  log "building Doctor images"
  DOCKER_BUILDKIT=1 docker build \
    --build-context "monofs=$ROOT/../monofs" \
    --build-arg DOCTOR_SERVICE=doctor-ingest \
    -t "$STRATA_IMAGE_PREFIX/doctor-ingest:$STRATA_IMAGE_TAG" \
    "$ROOT/../doctor"
  DOCKER_BUILDKIT=1 docker build \
    --build-context "monofs=$ROOT/../monofs" \
    --build-arg DOCTOR_SERVICE=doctor-query \
    -t "$STRATA_IMAGE_PREFIX/doctor-query:$STRATA_IMAGE_TAG" \
    "$ROOT/../doctor"

  log "building example application image"
  docker build -t "$STRATA_APP_IMAGE" "$ROOT/examples/onboarding-app/app"
fi

log "loading images into kind"
for image in \
  "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/guardiand:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/guardian-pusher-k8s:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/doctor-ingest:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/doctor-query:$STRATA_IMAGE_TAG" \
  "$STRATA_APP_IMAGE"; do
  kind load docker-image "$image" --name "$STRATA_KIND_CLUSTER"
done

log "creating namespace and secrets"
sed "s|__NAMESPACE__|$STRATA_NAMESPACE|g" "$ROOT/bootstrap/k8s/00-namespace.yaml" | kubectl apply -f -
apply_secrets

log "starting MonoFS fetcher"
apply_manifests "$ROOT/bootstrap/k8s/10-monofs-fetcher.yaml"
wait_rollout monofs-fetcher 180s

log "starting MonoFS"
apply_manifests "$ROOT/bootstrap/k8s/10-monofs.yaml"
wait_rollout monofs-server 300s
wait_rollout monofs-router 300s

log "starting Guardian"
apply_manifests "$ROOT/bootstrap/k8s/20-guardian.yaml"
wait_rollout guardiand 300s
wait_rollout guardian-pusher-k8s 300s

log "starting Doctor"
apply_manifests "$ROOT/bootstrap/k8s/30-doctor.yaml"
wait_rollout doctor-ingest 300s
wait_rollout doctor-query 300s

GUARDIANCTL="$(build_guardianctl)"

if ! $NO_PORT_FORWARD; then
  log "starting local port-forwards"
  start_port_forward monofs-grpc "svc/monofs-router" 19090 9090 || true
  start_port_forward monofs-node "svc/monofs-server" 9000 9000 || true
  start_port_forward monofs-http "svc/monofs-router" 18081 8080 || true
  start_port_forward guardian "svc/guardiand" 18090 8090 || true
  start_port_forward doctor "svc/doctor-query" 18080 18080 || true
fi

log "rendering and pushing the onboarding application partition"
APP_PARTITION_DIR="$STRATA_STATE_DIR/partitions/$STRATA_APP_PARTITION"
render_tree "$ROOT/bootstrap/partitions/$STRATA_APP_PARTITION" "$APP_PARTITION_DIR"
if $NO_PORT_FORWARD && [[ -z "${GUARDIAN_URL:-}" ]]; then
  warn "no port-forward and GUARDIAN_URL is unset; push the partition later with:"
  warn "  $GUARDIANCTL --guardian-url <url> partition push --dir $APP_PARTITION_DIR"
else
  push_partition "$GUARDIANCTL" "$APP_PARTITION_DIR"
fi

if ! $NO_PORT_FORWARD; then
  for _ in $(seq 1 90); do
    if [[ -n "$(kubectl -n "$STRATA_APP_PARTITION" get deployment -l guardian.asset=app -o name 2>/dev/null)" ]]; then
      break
    fi
    sleep 2
  done
  kubectl -n "$STRATA_APP_PARTITION" rollout status deployment -l guardian.asset=app --timeout=180s || true
  for _ in $(seq 1 30); do
    if start_app_port_forward; then
      break
    fi
    sleep 2
  done
fi

print_ready
