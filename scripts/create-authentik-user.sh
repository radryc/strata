#!/usr/bin/env bash
# Create a user in Authentik (and optionally grant it partition access).
#
#   ./scripts/create-authentik-user.sh --username alice --email alice@example.com \
#       [--name "Alice Example"] [--password secret] [--groups g1,g2] [--grant viewer|ingester|maintainer|admin] [--partition '*']
#
# Requires: kubectl (pointing at the kind cluster), jq, and the reference
# Authentik deployment: kubectl apply -f bootstrap/auth/authentik.yaml
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

NS=authentik
PORT=29020
USERNAME=""
EMAIL=""
NAME=""
PASSWORD="password"
GROUP_LIST=""
GRANT_ROLE=""
GRANT_PARTITION="*"

usage() {
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --username)  USERNAME="$2"; shift 2 ;;
        --email)     EMAIL="$2"; shift 2 ;;
        --name)      NAME="$2"; shift 2 ;;
        --password)  PASSWORD="$2"; shift 2 ;;
        --groups)    GROUP_LIST="$2"; shift 2 ;;
        --grant)     GRANT_ROLE="$2"; shift 2 ;;
        --partition) GRANT_PARTITION="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$USERNAME" && -n "$EMAIL" ]] || { echo "error: --username and --email are required" >&2; usage 1; }
[[ -n "$NAME" ]] || NAME="$USERNAME"
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

echo "→ reading Authentik API token from secret"
TOKEN=$(kubectl -n "$NS" get secret authentik -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' | base64 -d)
[[ -n "$TOKEN" ]] || { echo "error: could not read AUTHENTIK_BOOTSTRAP_TOKEN" >&2; exit 1; }

echo "→ port-forwarding svc/authentik ${PORT} -> 9000"
kubectl -n "$NS" port-forward svc/authentik "${PORT}:9000" >/tmp/ak-portforward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

BASE="http://localhost:${PORT}/api/v3"
echo -n "→ waiting for Authentik API"
for _ in $(seq 1 60); do
    if curl -sf "http://localhost:${PORT}/-/health/live/" >/dev/null 2>&1; then echo " ready"; break; fi
    echo -n "."; sleep 2
done

auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "→ creating user ${USERNAME} <${EMAIL}>"
resp=$(curl -s -X POST "${BASE}/core/users/" "${auth[@]}" \
    -d "{\"username\":\"${USERNAME}\",\"name\":\"${NAME}\",\"email\":\"${EMAIL}\",\"is_active\":true,\"type\":\"internal\"}")
pk=$(echo "$resp" | jq -r '.pk // empty')
if [[ -z "$pk" ]]; then
    # Already exists? look it up by username.
    pk=$(curl -s "${BASE}/core/users/?username=${USERNAME}" "${auth[@]}" | jq -r '.results[0].pk // empty')
fi
[[ -n "$pk" ]] || { echo "error: could not create/find user; response: $resp" >&2; exit 1; }
echo "  user pk=${pk}"

echo "→ setting password"
curl -s -o /dev/null -w '  set_password: HTTP %{http_code}\n' \
    -X POST "${BASE}/core/users/${pk}/set_password/" "${auth[@]}" \
    -d "{\"password\":\"${PASSWORD}\"}"

# Optional: join IdP groups (they arrive as the token's groups claim, which
# the Strata access policy matches by name).
if [[ -n "$GROUP_LIST" ]]; then
    IFS=',' read -r -a group_arr <<< "$GROUP_LIST"
    for g in "${group_arr[@]}"; do
        g="$(echo "$g" | xargs)"
        [[ -n "$g" ]] || continue
        gp=$(curl -s "${BASE}/core/groups/?name=${g}" "${auth[@]}" | jq -r '.results[0].pk // empty')
        if [[ -z "$gp" ]]; then
            gp=$(curl -s -X POST "${BASE}/core/groups/" "${auth[@]}" \
                -d "{\"name\":\"${g}\",\"is_superuser\":false}" | jq -r '.pk // empty')
        fi
        [[ -n "$gp" ]] || { echo "  ⚠ group ${g}: could not create/find" >&2; continue; }
        curl -s -o /dev/null -w "  group ${g}: HTTP %{http_code}\n" \
            -X POST "${BASE}/core/groups/${gp}/add_user/" "${auth[@]}" \
            -d "{\"pk\":${pk}}"
    done
fi

# Optional: grant partition access by patching the router + guardiand env.
if [[ -n "$GRANT_ROLE" ]]; then
    case "$GRANT_ROLE" in viewer|ingester|maintainer|admin) ;; *)
        echo "error: --grant must be viewer|ingester|maintainer|admin" >&2; exit 1 ;;
    esac
    add_grant() {
        local ns=$1 deploy=$2
        [[ -n "$deploy" ]] || return 0
        local cur merged
        cur=$(kubectl -n "$ns" get deploy "$deploy" \
            -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='MONOFS_AUTHZ_GRANTS_JSON')].value}" 2>/dev/null || true)
        [[ -n "$cur" ]] || cur='[]'
        merged=$(echo "$cur" | jq -c --arg s "$EMAIL" --arg p "$GRANT_PARTITION" --arg r "$GRANT_ROLE" \
            '. + [{subject:$s,partition:$p,role:$r}]')
        kubectl -n "$ns" set env "deploy/${deploy}" "MONOFS_AUTHZ_GRANTS_JSON=${merged}" >/dev/null
        kubectl -n "$ns" rollout restart "deploy/${deploy}" >/dev/null
        echo "  granted ${GRANT_ROLE} on '${GRANT_PARTITION}' via ${ns}/${deploy} (restarting)"
    }
    # Public bootstrap layout: both platform deployments live in the "strata"
    # namespace. Fall back to the legacy split namespaces when present.
    if kubectl -n strata get deploy monofs-router >/dev/null 2>&1; then
        echo "→ granting ${EMAIL} ${GRANT_ROLE} on '${GRANT_PARTITION}'"
        add_grant strata monofs-router || echo "  ⚠ router grant patch failed"
        add_grant strata guardiand     || echo "  ⚠ guardiand grant patch failed"
    else
        ROUTER=$(kubectl -n monofs get deploy -o name 2>/dev/null | grep -m1 router | sed 's|.*/||' || true)
        echo "→ granting ${EMAIL} ${GRANT_ROLE} on '${GRANT_PARTITION}'"
        add_grant monofs "$ROUTER"   || echo "  ⚠ router grant patch failed"
        add_grant guardian guardiand || echo "  ⚠ guardiand grant patch failed"
    fi

    # The grant patch restarts the platform pods; refresh the local
    # port-forwards so the UI and CLI reach the new pods.
    if [[ -f "$STRATA_ENV_FILE" ]]; then
        load_env
        for name in guardian ui-guardian ui-doctor ui-monofs monofs-grpc monofs-node; do
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
fi

cat <<EOF

✓ user ready
  username: ${USERNAME}
  email:    ${EMAIL}   (this is what authz grants match)
  password: ${PASSWORD}

Sign in at the Guardian, Doctor, or MonoFS login URL with:
  username/email: ${USERNAME} / ${EMAIL}
  password:       ${PASSWORD}

For CLI access, use the OIDC device flow:
  guardianctl auth login --issuer http://127.0.0.1:${PORT}/application/o/monofs/ \
    --client-id monofs --client-secret monofs-oidc-secret

If you did NOT pass --grant, the user is authenticated but has no partition
access yet. Grant it later by re-running with --grant, e.g.:
  ./scripts/create-authentik-user.sh --username ${USERNAME} --email ${EMAIL} --grant ingester --partition doctor
EOF
