#!/usr/bin/env bash
# Deploy Authentik into the local kind cluster and point the Strata UIs at it.
#
# Usage:
#   ./scripts/dev-kind-authentik.sh [--no-port-forward]
#
# After this, Guardian, MonoFS, and Doctor use Authentik OIDC:
#   Guardian : http://127.0.0.1:28090
#   Doctor   : http://127.0.0.1:28080
#   MonoFS   : http://127.0.0.1:28081
#   Authentik: http://127.0.0.1:29020  (akadmin / password)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

NO_PORT_FORWARD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-port-forward) NO_PORT_FORWARD=true; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

require kubectl "install kubectl"
load_env

log "deploying Authentik"
kubectl apply -f "$ROOT/bootstrap/auth/authentik.yaml"
kubectl -n authentik rollout status deploy/authentik-server --timeout=420s
kubectl -n authentik rollout status deploy/authentik-worker --timeout=240s
# The worker imports the OAuth2 blueprint shortly after startup. Restarting it
# makes an existing install pick up blueprint edits deterministically.
kubectl -n authentik rollout restart deploy/authentik-worker >/dev/null 2>&1 || true
kubectl -n authentik rollout status deploy/authentik-worker --timeout=180s >/dev/null 2>&1 || true

if ! $NO_PORT_FORWARD; then
  local_dir="$STRATA_STATE_DIR/pids"
  ensure_dir "$local_dir"
  pid_file="$local_dir/authentik.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    if (exec 3<>"/dev/tcp/127.0.0.1/29020") 2>/dev/null; then
      exec 3>&- 3<&-
    else
      kill "$(cat "$pid_file")" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  fi
  if [[ ! -f "$pid_file" ]]; then
    log_file="$STRATA_STATE_DIR/logs/authentik.log"
    ensure_dir "$(dirname "$log_file")"
    setsid kubectl -n authentik port-forward svc/authentik 29020:9000 >"$log_file" 2>&1 </dev/null &
    echo $! >"$pid_file"
    for _ in $(seq 1 60); do
      if (exec 3<>"/dev/tcp/127.0.0.1/29020") 2>/dev/null; then
        exec 3>&- 3<&-
        break
      fi
      sleep 1
    done
  fi
fi

log "pointing Guardian, MonoFS, and Doctor at Authentik"
kubectl -n "$STRATA_NAMESPACE" set env deploy/guardiand \
  MONOFS_OIDC_ISSUER=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/ \
  MONOFS_OIDC_AUDIENCE=monofs \
  MONOFS_OIDC_CLIENT_ID=monofs \
  MONOFS_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  MONOFS_OIDC_REDIRECT_URL=http://127.0.0.1:28090/auth/callback \
  MONOFS_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \
  MONOFS_OIDC_END_SESSION_URL=http://127.0.0.1:29020/application/o/monofs/end-session/ \
  MONOFS_AUTHZ_ENFORCE_UI=false \
  GUARDIAN_REQUIRE_UI_AUTH=true \
  MONOFS_AUTHZ_GRANTS_JSON='[{"subject":"admin@example.com","partition":"*","role":"admin"}]' >/dev/null

# MonoFS reads issuer/audience from flags, not environment variables.
router_args="$(kubectl -n "$STRATA_NAMESPACE" get deploy monofs-router -o jsonpath='{.spec.template.spec.containers[0].args}')"
if [[ "$router_args" != *"--oidc-issuer="* ]]; then
  kubectl -n "$STRATA_NAMESPACE" patch deploy monofs-router --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--oidc-issuer=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--oidc-audience=monofs"}
  ]' >/dev/null
fi

kubectl -n "$STRATA_NAMESPACE" set env deploy/monofs-router \
  MONOFS_OIDC_ISSUER=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/ \
  MONOFS_OIDC_AUDIENCE=monofs \
  MONOFS_OIDC_CLIENT_ID=monofs \
  MONOFS_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  MONOFS_ROUTER_OIDC_REDIRECT_URL=http://127.0.0.1:28081/auth/callback \
  MONOFS_ROUTER_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \
  MONOFS_ROUTER_OIDC_END_SESSION_URL=http://127.0.0.1:29020/application/o/monofs/end-session/ \
  MONOFS_AUTHZ_ENFORCE_UI=true \
  MONOFS_AUTHZ_GRANTS_JSON='[{"subject":"admin@example.com","partition":"*","role":"admin"}]' \
  MONOFS_INSECURE_DEV_DISABLE_AUTH- >/dev/null

kubectl -n "$STRATA_NAMESPACE" set env deploy/doctor-query \
  DOCTOR_AUTH_REQUIRE=false \
  DOCTOR_OIDC_ISSUER=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/ \
  DOCTOR_OIDC_AUDIENCE=monofs \
  DOCTOR_OIDC_CLIENT_ID=monofs \
  DOCTOR_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  DOCTOR_OIDC_REDIRECT_URL=http://127.0.0.1:28080/auth/callback \
  DOCTOR_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \
  DOCTOR_OIDC_REQUIRE_LOGIN=true \
  DOCTOR_OIDC_SCOPES=openid,email,profile >/dev/null

for deploy in guardiand monofs-router doctor-query; do
  kubectl -n "$STRATA_NAMESPACE" rollout restart "deploy/$deploy" >/dev/null
  kubectl -n "$STRATA_NAMESPACE" rollout status "deploy/$deploy" --timeout=180s
done

# Restart the API port-forwards: a service port-forward pins the pod that was
# selected when it started, and the auth rollout replaces those pods.
if ! $NO_PORT_FORWARD; then
  for name in guardian monofs-grpc monofs-node ui-guardian ui-doctor ui-monofs; do
    pid_file="$STRATA_STATE_DIR/pids/$name.pid"
    if [[ -f "$pid_file" ]]; then
      kill "$(cat "$pid_file")" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
  start_port_forward guardian "svc/guardiand" 18090 8090 || true
  start_port_forward ui-guardian "svc/guardiand" 28090 8090 || true
  start_port_forward ui-doctor "svc/doctor-query" 28080 18080 || true
  start_port_forward ui-monofs "svc/monofs-router" 28081 8080 || true
  start_port_forward monofs-grpc "svc/monofs-router" 19090 9090 || true
  start_port_forward monofs-node "svc/monofs-server" 9000 9000 || true
  start_app_port_forward || true
fi

if ! $NO_PORT_FORWARD; then
  if ! (exec 3<>"/dev/tcp/127.0.0.1/29020") 2>/dev/null; then
    pid_file="$STRATA_STATE_DIR/pids/authentik.pid"
    [[ -f "$pid_file" ]] && kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
    log_file="$STRATA_STATE_DIR/logs/authentik.log"
    setsid kubectl -n authentik port-forward svc/authentik 29020:9000 >"$log_file" 2>&1 </dev/null &
    echo $! >"$pid_file"
    for _ in $(seq 1 60); do
      if (exec 3<>"/dev/tcp/127.0.0.1/29020") 2>/dev/null; then
        exec 3>&- 3<&-
        break
      fi
      sleep 1
    done
  fi
fi

cat <<EOF

Authentik SSO is enabled.

  Authentik : http://127.0.0.1:29020   (akadmin / password)
  Guardian  : http://127.0.0.1:28090
  Doctor    : http://127.0.0.1:28080
  MonoFS    : http://127.0.0.1:28081

The admin email admin@example.com is granted admin on all partitions.

Create additional users (and optionally grant access):
  ./scripts/create-authentik-user.sh \\
    --username alice --email alice@example.com --password 'choose-a-password' \\
    --grant maintainer --partition onboarding-app

For CLI access:
  guardianctl auth login \\
    --issuer http://127.0.0.1:29020/application/o/monofs/ \\
    --client-id monofs --client-secret monofs-oidc-secret

EOF
