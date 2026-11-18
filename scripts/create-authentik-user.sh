#!/usr/bin/env bash
# Create a user in Authentik (and optionally print the access-policy grant to add).
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

# Optional: print the access-policy grant to add. Authorization is decided by
# the repo-managed ACL (access/envs/<env>.yaml), not by process environment.
if [[ -n "$GRANT_ROLE" ]]; then
    case "$GRANT_ROLE" in viewer|ingester|maintainer|admin) ;; *)
        echo "error: --grant must be viewer|ingester|maintainer|admin" >&2; exit 1 ;;
    esac
    echo
    echo "→ grant requested: ${EMAIL} ${GRANT_ROLE} on '${GRANT_PARTITION}'"
    echo "  Add this to access/envs/<env>.yaml under users: (add logs/traces/monofs"
    echo "  scopes as appropriate), then publish it:"
    echo
    echo "    users:"
    echo "      ${EMAIL}:"
    echo "        partitions: [\"${GRANT_PARTITION}\"]"
    echo "        role: ${GRANT_ROLE}"
    echo
    echo "    guardianctl access lint    --file access/envs/dev.yaml"
    echo "    guardianctl access publish --file access/envs/dev.yaml --env dev"
    echo
fi

cat <<EOF

✓ user ready
  username: ${USERNAME}
  email:    ${EMAIL}   (this is the access-policy subject)
  password: ${PASSWORD}

Sign in at the Guardian, Doctor, or MonoFS login URL with:
  username/email: ${USERNAME} / ${EMAIL}
  password:       ${PASSWORD}

For CLI access, use the OIDC device flow:
  guardianctl auth login --issuer http://127.0.0.1:${PORT}/application/o/monofs/ \
    --client-id monofs --client-secret monofs-oidc-secret

Add partition access by editing access/envs/<env>.yaml and publishing it with
\`guardianctl access publish\`. The access policy is the single runtime
authorization source for Guardian, MonoFS, and Doctor.
EOF
