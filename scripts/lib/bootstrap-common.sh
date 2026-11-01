#!/usr/bin/env bash
# Shared helpers for the public Strata bootstrap scripts.
set -euo pipefail

STRATA_ROOT="${STRATA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STRATA_STATE_DIR="${STRATA_STATE_DIR:-$STRATA_ROOT/.strata}"
STRATA_ENV_FILE="${STRATA_ENV_FILE:-$STRATA_STATE_DIR/dev.env}"
STRATA_NAMESPACE="${STRATA_NAMESPACE:-strata}"
STRATA_KIND_CLUSTER="${STRATA_KIND_CLUSTER:-strata-dev}"
STRATA_IMAGE_PREFIX="${STRATA_IMAGE_PREFIX:-strata}"
STRATA_IMAGE_TAG="${STRATA_IMAGE_TAG:-dev}"
STRATA_APP_IMAGE="${STRATA_APP_IMAGE:-$STRATA_IMAGE_PREFIX/onboarding-app:$STRATA_IMAGE_TAG}"
STRATA_APP_PARTITION="${STRATA_APP_PARTITION:-onboarding-app}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

require() {
  local tool="$1" hint="${2:-}"
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required${hint:+ ($hint)}"
}

ensure_dir() { mkdir -p "$1"; }

load_env() {
  ensure_dir "$STRATA_STATE_DIR"
  if [[ -f "$STRATA_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$STRATA_ENV_FILE"; set +a
  fi
}

save_env() {
  ensure_dir "$STRATA_STATE_DIR"
  umask 077
  {
    printf 'MONOFS_TOKEN=%s\n' "$MONOFS_TOKEN"
    printf 'MONOFS_ENCRYPTION_KEY=%s\n' "$MONOFS_ENCRYPTION_KEY"
    printf 'DOCTOR_INGEST_AUTH_TOKEN=%s\n' "$DOCTOR_INGEST_AUTH_TOKEN"
    printf 'DOCTOR_PRIVACY_HMAC_KEY=%s\n' "$DOCTOR_PRIVACY_HMAC_KEY"
    printf 'STRATA_NAMESPACE=%s\n' "$STRATA_NAMESPACE"
    printf 'STRATA_KIND_CLUSTER=%s\n' "$STRATA_KIND_CLUSTER"
    printf 'STRATA_IMAGE_PREFIX=%s\n' "$STRATA_IMAGE_PREFIX"
    printf 'STRATA_IMAGE_TAG=%s\n' "$STRATA_IMAGE_TAG"
    printf 'STRATA_APP_IMAGE=%s\n' "$STRATA_APP_IMAGE"
  } >"$STRATA_ENV_FILE"
}

ensure_secrets() {
  load_env
  [[ -n "${MONOFS_TOKEN:-}" ]] || MONOFS_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${MONOFS_ENCRYPTION_KEY:-}" ]] || MONOFS_ENCRYPTION_KEY="$(openssl rand -hex 32)"
  [[ -n "${DOCTOR_INGEST_AUTH_TOKEN:-}" ]] || DOCTOR_INGEST_AUTH_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${DOCTOR_PRIVACY_HMAC_KEY:-}" ]] || DOCTOR_PRIVACY_HMAC_KEY="$(openssl rand -hex 32)"
  save_env
  export MONOFS_TOKEN MONOFS_ENCRYPTION_KEY DOCTOR_INGEST_AUTH_TOKEN DOCTOR_PRIVACY_HMAC_KEY
}

ensure_siblings() {
  local missing=0
  for repo in monofs guardian doctor kvs; do
    if [[ ! -d "$STRATA_ROOT/../$repo" ]]; then
      warn "missing sibling checkout: $STRATA_ROOT/../$repo"
      missing=1
    fi
  done
  if (( missing )); then
    log "cloning the public repositories into $(dirname "$STRATA_ROOT")"
    "$STRATA_ROOT/scripts/clone.sh" "$(dirname "$STRATA_ROOT")"
  fi
}

require_siblings() {
  for repo in monofs guardian doctor kvs; do
    [[ -d "$STRATA_ROOT/../$repo" ]] || die "missing $repo checkout next to $STRATA_ROOT (run scripts/clone.sh)"
  done
}

render_template() {
  local source="$1" dest="$2"
  sed \
    -e "s|__IMAGE_PREFIX__|$STRATA_IMAGE_PREFIX|g" \
    -e "s|__IMAGE_TAG__|$STRATA_IMAGE_TAG|g" \
    -e "s|__APP_IMAGE__|$STRATA_APP_IMAGE|g" \
    -e "s|__NAMESPACE__|$STRATA_NAMESPACE|g" \
    "$source" >"$dest"
}

render_tree() {
  local source_dir="$1" dest_dir="$2"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  while IFS= read -r -d '' file; do
    local rel="${file#"$source_dir"/}"
    local dest="$dest_dir/$rel"
    mkdir -p "$(dirname "$dest")"
    render_template "$file" "$dest"
  done < <(find "$source_dir" -type f -print0)
}

apply_secrets() {
  kubectl -n "$STRATA_NAMESPACE" create secret generic strata-secrets \
    --from-literal="MONOFS_TOKEN=$MONOFS_TOKEN" \
    --from-literal="MONOFS_ENCRYPTION_KEY=$MONOFS_ENCRYPTION_KEY" \
    --from-literal="DOCTOR_INGEST_AUTH_TOKEN=$DOCTOR_INGEST_AUTH_TOKEN" \
    --from-literal="DOCTOR_PRIVACY_HMAC_KEY=$DOCTOR_PRIVACY_HMAC_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_manifests() {
  local source="$1"
  shift || true
  local rendered="$STRATA_STATE_DIR/rendered-k8s"
  if [[ -d "$source" ]]; then
    render_tree "$source" "$rendered"
    kubectl apply -f "$rendered" "$@"
    return
  fi
  ensure_dir "$rendered"
  local dest="$rendered/$(basename "$source")"
  render_template "$source" "$dest"
  kubectl apply -f "$dest" "$@"
}

wait_rollout() {
  local name="$1" timeout="${2:-300s}"
  kubectl -n "$STRATA_NAMESPACE" rollout status "deployment/$name" --timeout="$timeout"
}

start_port_forward() {
  local name="$1" target="$2" local_port="$3" remote_port="$4"
  local pid_dir="$STRATA_STATE_DIR/pids"
  ensure_dir "$pid_dir"
  local pid_file="$pid_dir/$name.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
      exec 3>&- 3<&-
      log "port-forward $name already running (pid $(cat "$pid_file"))"
      return 0
    fi
    kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi
  local log_file="$STRATA_STATE_DIR/logs/$name.log"
  ensure_dir "$(dirname "$log_file")"
  setsid kubectl -n "$STRATA_NAMESPACE" port-forward "$target" "$local_port:$remote_port" \
    >"$log_file" 2>&1 </dev/null &
  echo $! >"$pid_file"
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
      exec 3>&- 3<&-
      log "port-forward $name ready on 127.0.0.1:$local_port"
      return 0
    fi
    sleep 0.5
  done
  warn "port-forward $name did not become ready; see $log_file"
  return 1
}

start_app_port_forward() {
  local name="onboarding-app" local_port="18088"
  local pid_dir="$STRATA_STATE_DIR/pids"
  ensure_dir "$pid_dir"
  local pid_file="$pid_dir/$name.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi
  local service
  service="$(kubectl -n "$STRATA_APP_PARTITION" get svc -l guardian.asset=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$service" ]] || return 1
  local log_file="$STRATA_STATE_DIR/logs/$name.log"
  ensure_dir "$(dirname "$log_file")"
  setsid kubectl -n "$STRATA_APP_PARTITION" port-forward "svc/$service" "$local_port:8080" \
    >"$log_file" 2>&1 </dev/null &
  echo $! >"$pid_file"
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then
      exec 3>&- 3<&-
      log "onboarding app ready on http://127.0.0.1:$local_port"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

stop_port_forwards() {
  local pid_dir="$STRATA_STATE_DIR/pids"
  [[ -d "$pid_dir" ]] || return 0
  for pid_file in "$pid_dir"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
}

build_guardianctl() {
  local bin="$STRATA_STATE_DIR/bin"
  ensure_dir "$bin"
  log "building guardianctl" >&2
  (cd "$STRATA_ROOT/../guardian" && go build -o "$bin/guardianctl" ./cmd/guardianctl)
  printf '%s\n' "$bin/guardianctl"
}

push_partition() {
  local guardianctl="$1" dir="$2"
  local url="${GUARDIAN_URL:-http://127.0.0.1:18090}"
  log "pushing partition bundle from $dir"
  "$guardianctl" --guardian-url "$url" partition push --dir "$dir"
}

print_ready() {
  cat <<EOF

Strata is running.

  Guardian UI : http://127.0.0.1:18090
  Doctor UI   : http://127.0.0.1:18080
  MonoFS UI   : http://127.0.0.1:18081
  Sample app  : http://127.0.0.1:18088

  Kubernetes  : kubectl -n $STRATA_NAMESPACE get pods
  Logs        : kubectl -n $STRATA_NAMESPACE logs deploy/guardiand -f
  State       : $STRATA_STATE_DIR

  Teardown    : ./scripts/dev-kind-down.sh
EOF
}
