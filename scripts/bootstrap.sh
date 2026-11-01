#!/usr/bin/env bash
# Public Strata bootstrap dispatcher.
#
#   ./scripts/bootstrap.sh up                 # local kind developer stack
#   ./scripts/bootstrap.sh down               # tear down kind
#   ./scripts/bootstrap.sh k8s [flags]        # deploy to current kubeconfig
#   ./scripts/bootstrap.sh k8s-down           # remove from current cluster
#   ./scripts/bootstrap.sh aws [flags]        # deploy the AWS CDK stack
#   ./scripts/bootstrap.sh onboard --repo DIR # register an app repository
#   ./scripts/bootstrap.sh authentik           # re-apply local Authentik SSO
#
# The older demo-divisions harness can still be reached explicitly:
#   STRATA_DEMO_DIR=../demo-divisions ./scripts/bootstrap.sh demo up
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-help}"
shift || true

case "$CMD" in
  up)          exec "$ROOT/scripts/dev-kind-up.sh" "$@" ;;
  down)        exec "$ROOT/scripts/dev-kind-down.sh" "$@" ;;
  k8s)         exec "$ROOT/scripts/k8s-up.sh" "$@" ;;
  k8s-down)    exec "$ROOT/scripts/k8s-down.sh" "$@" ;;
  aws)         exec "$ROOT/scripts/aws-up.sh" "$@" ;;
  onboard)     exec "$ROOT/scripts/onboard-app.sh" "$@" ;;
  authentik)   exec "$ROOT/scripts/dev-kind-authentik.sh" "$@" ;;
  demo)
    DEMO_DIR="${STRATA_DEMO_DIR:-$ROOT/../demo-divisions}"
    DEMO="$DEMO_DIR/demo.sh"
    [[ -x "$DEMO" ]] || {
      printf 'error: demo harness not found at %s\n' "$DEMO" >&2
      printf 'Set STRATA_DEMO_DIR or use the public commands: up, k8s, aws.\n' >&2
      exit 1
    }
    exec "$DEMO" "$@"
    ;;
  help|-h|--help)
    awk 'NR>1 && /^#/ { print; next } NR>1 && /^$/ { if (seen) exit; next } NR>1 { exit } { seen=1 }' "$0"
    ;;
  *)
    printf 'unknown command: %s\n\n' "$CMD" >&2
    sed -n '2,18p' "$0" >&2
    exit 2
    ;;
esac
