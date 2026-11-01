#!/usr/bin/env bash
# Register an application repository with Guardian and import its dedicated
# partition.
#
# Usage:
#   ./scripts/onboard-app.sh --repo ../my-app [--name my-app] [--partition my-app]
#
# The repository should contain:
#   .guardian/config.yaml
#   guardian/partitions/<partition>/{config.yaml,intents/*.yaml}
#
# If the repository has no .guardian/config.yaml, pass --name and --partition;
# the script registers it with the k8s-main pusher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap-common.sh
source "$ROOT/scripts/lib/bootstrap-common.sh"

REPO=""
NAME=""
PARTITION=""
PUSHER="k8s-main"
GUARDIAN_URL="${GUARDIAN_URL:-http://127.0.0.1:18090}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires a path}"; shift 2 ;;
    --name) NAME="${2:?--name requires a value}"; shift 2 ;;
    --partition) PARTITION="${2:?--partition requires a value}"; shift 2 ;;
    --pusher) PUSHER="${2:?--pusher requires a value}"; shift 2 ;;
    --guardian-url) GUARDIAN_URL="${2:?--guardian-url requires a value}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "--repo is required"
REPO="$(cd "$REPO" && pwd)"
[[ -d "$REPO/guardian/partitions" ]] || die "$REPO does not contain guardian/partitions/<name>/"

if [[ -f "$REPO/.guardian/config.yaml" ]]; then
  [[ -n "$NAME" ]] || NAME="$(awk '/^repo:/{f=1;next} f&&/^  name:/{print $2; exit}' "$REPO/.guardian/config.yaml")"
  [[ -n "$PARTITION" ]] || PARTITION="$(awk '/^repo:/{f=1;next} f&&/^  partition:/{print $2; exit}' "$REPO/.guardian/config.yaml")"
  config_pusher="$(awk '/^pusher:/{f=1;next} f&&/^  name:/{print $2; exit}' "$REPO/.guardian/config.yaml")"
  [[ -n "$config_pusher" ]] && PUSHER="$config_pusher"
fi
[[ -n "$NAME" ]] || die "--name is required when .guardian/config.yaml is absent"
[[ -n "$PARTITION" ]] || die "--partition is required when .guardian/config.yaml is absent"

GUARDIANCTL="$(build_guardianctl)"
log "registering $NAME -> $PARTITION via pusher $PUSHER"
"$GUARDIANCTL" --guardian-url "$GUARDIAN_URL" repo add \
  --name "$NAME" --pusher "$PUSHER" --partition "$PARTITION" --source "$REPO"
"$GUARDIANCTL" --guardian-url "$GUARDIAN_URL" repo import --name "$NAME" --source "$REPO"

log "partition imported; watch it with:"
printf '  %s --guardian-url %s partition status --partition %s\n' \
  "$GUARDIANCTL" "$GUARDIAN_URL" "${PARTITION:-<partition>}"
