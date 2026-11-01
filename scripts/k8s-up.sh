#!/usr/bin/env bash
# Deploy Strata to an existing Kubernetes cluster (not kind).
#
# Usage:
#   ./scripts/k8s-up.sh [--build] [--push] [--no-port-forward] [--skip-app]
#
# Environment:
#   KUBECONFIG             target cluster
#   STRATA_IMAGE_PREFIX    registry/repository prefix (default: strata)
#   STRATA_IMAGE_TAG       image tag (default: dev)
#   STRATA_APP_IMAGE       application image reference
#   STRATA_NAMESPACE       control-plane namespace (default: strata)
#
# For a remote cluster, pass --build --push after `docker login` so the
# images are available to the nodes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

BUILD=false
PUSH=false
NO_PORT_FORWARD=false
SKIP_APP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=true; shift ;;
    --push) PUSH=true; shift ;;
    --no-port-forward) NO_PORT_FORWARD=true; shift ;;
    --skip-app) SKIP_APP=true; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

require kubectl "install kubectl"
require openssl "install OpenSSL"
ensure_siblings
require_siblings
ensure_secrets

if $BUILD; then
  require docker "install Docker"
  log "building images with prefix $STRATA_IMAGE_PREFIX:$STRATA_IMAGE_TAG"
  docker build --target router -t "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target server -t "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target fetcher -t "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  DOCKER_BUILDKIT=1 docker build --build-context "monofs=$ROOT/../monofs" --build-context "kvs=$ROOT/../kvs" \
    -t "$STRATA_IMAGE_PREFIX/guardiand:$STRATA_IMAGE_TAG" "$ROOT/../guardian"
  DOCKER_BUILDKIT=1 docker build --build-context "monofs=$ROOT/../monofs" --build-context "kvs=$ROOT/../kvs" \
    -f "$ROOT/../guardian/Dockerfile.pusher-k8s" \
    -t "$STRATA_IMAGE_PREFIX/guardian-pusher-k8s:$STRATA_IMAGE_TAG" "$ROOT/../guardian"
  DOCKER_BUILDKIT=1 docker build --build-context "monofs=$ROOT/../monofs" --build-arg DOCTOR_SERVICE=doctor-ingest \
    -t "$STRATA_IMAGE_PREFIX/doctor-ingest:$STRATA_IMAGE_TAG" "$ROOT/../doctor"
  DOCKER_BUILDKIT=1 docker build --build-context "monofs=$ROOT/../monofs" --build-arg DOCTOR_SERVICE=doctor-query \
    -t "$STRATA_IMAGE_PREFIX/doctor-query:$STRATA_IMAGE_TAG" "$ROOT/../doctor"
  docker build -t "$STRATA_APP_IMAGE" "$ROOT/examples/onboarding-app/app"
fi

if $PUSH; then
  require docker "install Docker"
  log "pushing images to $STRATA_IMAGE_PREFIX"
  for image in monofs-router monofs-server monofs-fetcher guardiand guardian-pusher-k8s doctor-ingest doctor-query; do
    docker push "$STRATA_IMAGE_PREFIX/$image:$STRATA_IMAGE_TAG"
  done
  docker push "$STRATA_APP_IMAGE"
fi

log "creating namespace and secrets"
sed "s|__NAMESPACE__|$STRATA_NAMESPACE|g" "$ROOT/bootstrap/k8s/00-namespace.yaml" | kubectl apply -f -
apply_secrets

log "applying MonoFS fetcher"
apply_manifests "$ROOT/bootstrap/k8s/10-monofs-fetcher.yaml"
wait_rollout monofs-fetcher 180s

log "applying MonoFS"
apply_manifests "$ROOT/bootstrap/k8s/10-monofs.yaml"
wait_rollout monofs-server 300s
wait_rollout monofs-router 300s

log "applying Guardian"
apply_manifests "$ROOT/bootstrap/k8s/20-guardian.yaml"
wait_rollout guardiand 300s
wait_rollout guardian-pusher-k8s 300s

log "applying Doctor"
apply_manifests "$ROOT/bootstrap/k8s/30-doctor.yaml"
wait_rollout doctor-ingest 300s
wait_rollout doctor-query 300s

GUARDIANCTL="$(build_guardianctl)"
if ! $NO_PORT_FORWARD; then
  start_port_forward monofs-grpc "svc/monofs-router" 19090 9090 || true
  start_port_forward monofs-node "svc/monofs-server" 9000 9000 || true
  start_port_forward monofs-http "svc/monofs-router" 18081 8080 || true
  start_port_forward guardian "svc/guardiand" 18090 8090 || true
  start_port_forward doctor "svc/doctor-query" 18080 18080 || true
fi

if ! $SKIP_APP; then
  if $NO_PORT_FORWARD && [[ -z "${GUARDIAN_URL:-}" ]]; then
    warn "skipping app partition push: set GUARDIAN_URL or enable port-forwarding"
  else
    APP_PARTITION_DIR="$STRATA_STATE_DIR/partitions/$STRATA_APP_PARTITION"
    render_tree "$ROOT/bootstrap/partitions/$STRATA_APP_PARTITION" "$APP_PARTITION_DIR"
    push_partition "$GUARDIANCTL" "$APP_PARTITION_DIR"
  fi
fi

print_ready
