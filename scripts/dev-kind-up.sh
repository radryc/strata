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

# The kind dev stack runs MonoFS without TLS. Guardian and its CLI fail closed
# on plaintext unless the local-development escape hatch is set explicitly.
export GUARDIAN_MONOFS_ALLOW_PLAINTEXT=true
export GUARDIAN_ALLOW_UNKEYED_ARCHIVE=true

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
  # The monofs Dockerfile pins github.com/radryc/kvs. Its default pin
  # (e0e1989) enforces bearer auth on every RPC on the shared gRPC server,
  # which breaks router->node health probes. Pin the fix that scopes bearer
  # enforcement to KVStore RPCs until monofs bumps its default.
  kvs_ref="a33057cf2ba3c1055eda8fe44a9b5d771c7e857f"
  docker build --target router --build-arg "KVS_REF=$kvs_ref" -t "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target server --build-arg "KVS_REF=$kvs_ref" -t "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build --target fetcher --build-arg "KVS_REF=$kvs_ref" -t "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build -f "$ROOT/../monofs/Dockerfile.logquery" --build-arg "KVS_REF=$kvs_ref" -t "$STRATA_IMAGE_PREFIX/monofs-logquery:$STRATA_IMAGE_TAG" "$ROOT/../monofs"
  docker build -f "$ROOT/../monofs/Dockerfile.search" -t "$STRATA_IMAGE_PREFIX/monofs-search:$STRATA_IMAGE_TAG" "$ROOT/../monofs"

  log "building MonoFS client image (Agent workspace)"
  monofs_client_image="$STRATA_IMAGE_PREFIX/monofs-client:$STRATA_IMAGE_TAG"
  docker build --target client --build-arg "KVS_REF=$kvs_ref" -t "$monofs_client_image" "$ROOT/../monofs"

  log "building LB Edge image"
  docker build -t "$STRATA_IMAGE_PREFIX/lb-edge:$STRATA_IMAGE_TAG" "$ROOT/../lb"

  log "building Agent images"
  docker build \
    --build-arg "MONOFS_CLIENT_IMAGE=$monofs_client_image" \
    -t "$STRATA_IMAGE_PREFIX/lagent-backend:$STRATA_IMAGE_TAG" \
    "$ROOT/../agent/backend"
  docker build \
    -t "$STRATA_IMAGE_PREFIX/lagent-frontend:$STRATA_IMAGE_TAG" \
    "$ROOT/../agent/frontend"

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
  DOCKER_BUILDKIT=1 docker build \
    --build-context "monofs=$ROOT/../monofs" \
    --build-arg DOCTOR_SERVICE=doctor-sentinel \
    -t "$STRATA_IMAGE_PREFIX/doctor-sentinel:$STRATA_IMAGE_TAG" \
    "$ROOT/../doctor"

  log "building example application image"
  docker build -t "$STRATA_APP_IMAGE" "$ROOT/examples/onboarding-app/app"
fi

log "loading images into kind"
for image in \
  "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-logquery:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/monofs-search:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/guardiand:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/guardian-pusher-k8s:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/doctor-ingest:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/doctor-query:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/doctor-sentinel:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/lb-edge:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/lagent-backend:$STRATA_IMAGE_TAG" \
  "$STRATA_IMAGE_PREFIX/lagent-frontend:$STRATA_IMAGE_TAG" \
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

log "starting MonoFS search"
apply_manifests "$ROOT/bootstrap/k8s/15-monofs-search.yaml"
wait_rollout monofs-search 180s

log "starting Guardian"
apply_manifests "$ROOT/bootstrap/k8s/20-guardian.yaml"
wait_rollout guardiand 300s
wait_rollout guardian-pusher-k8s 300s

log "starting Doctor"
apply_manifests "$ROOT/bootstrap/k8s/30-doctor.yaml"
wait_rollout doctor-ingest 300s
wait_rollout doctor-query 300s
wait_rollout doctor-sentinel 300s

# The Agent's LLM runs on the host through Ollama by default. Pods reach the
# host through the kind bridge gateway; override STRATA_LLM_BASE_URL/STRATA_LLM_MODEL
# to use another OpenAI-compatible server.
STRATA_HOST_GATEWAY="${STRATA_HOST_GATEWAY:-$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)}"
export STRATA_HOST_GATEWAY="${STRATA_HOST_GATEWAY:-172.17.0.1}"
export STRATA_LLM_BASE_URL="${STRATA_LLM_BASE_URL:-http://${STRATA_HOST_GATEWAY}:11434}"
export STRATA_LLM_MODEL="${STRATA_LLM_MODEL:-gemma4:e4b}"
if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  warn "Ollama is not reachable on 127.0.0.1:11434; Agent chat needs STRATA_LLM_BASE_URL"
fi

# Authentik must be running before the Agent starts: the backend obtains OIDC
# client-credentials tokens at startup and fails closed without them.
log "enabling Authentik SSO"
if $NO_PORT_FORWARD; then
  "$ROOT/scripts/dev-kind-authentik.sh" --no-port-forward
else
  "$ROOT/scripts/dev-kind-authentik.sh"
fi
export STRATA_AUTH_MODE=authentik

log "starting LB Edge"
apply_manifests "$ROOT/bootstrap/k8s/40-lb.yaml"
wait_rollout lb-edge 180s
wait_rollout lb-k8s-agent 180s

log "starting Agent"
apply_manifests "$ROOT/bootstrap/k8s/50-agent.yaml"
wait_rollout lagent-backend 300s
wait_rollout lagent-nightwatch 300s
wait_rollout lagent-frontend 180s

GUARDIANCTL="$(build_guardianctl)"

if ! $NO_PORT_FORWARD; then
  log "starting local port-forwards"
  # Clear forwards from previous runs: they pin a pod, so a rollout since the
  # last bootstrap leaves them alive but unusable until the next request. Keep
  # the Authentik forward, which lives in another namespace and is managed by
  # dev-kind-authentik.sh.
  for name in monofs-grpc monofs-node guardian ui-guardian ui-doctor ui-monofs \
    lb-registry lb-edge-route agent onboarding-app; do
    pid_file="$STRATA_STATE_DIR/pids/$name.pid"
    if [[ -f "$pid_file" ]]; then
      kill "$(cat "$pid_file")" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
  start_port_forward monofs-grpc "svc/monofs-router" 19090 9090 || true
  start_port_forward monofs-node "svc/monofs-server" 9000 9000 || true
  start_port_forward guardian "svc/guardiand" 18090 8090 || true
  start_port_forward ui-guardian "svc/guardiand" 28090 8090 || true
  start_port_forward ui-doctor "svc/doctor-query" 28080 18080 || true
  start_port_forward ui-monofs "svc/monofs-router" 28081 8080 || true
  start_port_forward lb-registry "svc/lb-edge" 18081 18081 || true
  start_port_forward agent "svc/lagent-frontend" 3000 3000 || true
fi

if ! $NO_PORT_FORWARD; then
  register_platform_repositories "$GUARDIANCTL" "127.0.0.1:19090"
else
  warn "no port-forward: skipping platform repo ingestion/registration"
fi

log "rendering and pushing the onboarding application partition"
if ! $NO_PORT_FORWARD; then
  export STRATA_MONOFS_DIRECT=true
  export MONOFS_DIRECT_ROUTER=127.0.0.1:19090
fi
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

  # Advertise the deployed app through LB Edge. The endpoints agent watches
  # annotated Services and opens a matching proxy listener.
  kubectl -n "$STRATA_APP_PARTITION" annotate svc -l guardian.asset=app \
    guardian.intent/expose=true guardian.intent/external-port=28088 --overwrite >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if curl -sf --max-time 2 http://127.0.0.1:18081/services 2>/dev/null | grep -q '28088'; then
      break
    fi
    sleep 2
  done
  start_port_forward lb-edge-route "svc/lb-edge" 28088 28088 || true
fi

print_ready
