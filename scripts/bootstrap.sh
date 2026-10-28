#!/usr/bin/env bash
# Delegate to the Strata workspace bootstrap harness.
#
# The harness lives in demo-divisions/demo.sh next to the source checkouts.
# This wrapper keeps a single entrypoint in the umbrella repo:
#
#   ./scripts/bootstrap.sh up
#   ./scripts/bootstrap.sh start --k8s
#   ./scripts/bootstrap.sh control-plane --aws up
#
# Environment:
#   STRATA_DEMO_DIR=../demo-divisions   directory containing demo.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="${STRATA_DEMO_DIR:-$ROOT/../demo-divisions}"
DEMO="$DEMO_DIR/demo.sh"

if [[ ! -x "$DEMO" ]]; then
  printf 'Strata demo harness not found at %s\n\n' "$DEMO" >&2
  printf 'The full bootstrap lives in demo-divisions/demo.sh. Set\n' >&2
  printf 'STRATA_DEMO_DIR to that directory, or run the script directly.\n' >&2
  exit 1
fi

exec "$DEMO" "$@"
