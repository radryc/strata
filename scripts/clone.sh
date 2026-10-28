#!/usr/bin/env bash
# Clone the public Strata repositories next to this checkout.
#
# Usage:
#   ./scripts/clone.sh [target-dir]
#
# target-dir defaults to the parent of this repository, which produces the
# sibling layout expected by the Go replace directives:
#
#   strata/          this repo
#   monofs/          sibling checkouts
#   guardian/
#   ...
#
# Environment:
#   STRATA_ORG=radryc       GitHub owner
#   STRATA_PROTO=https      https or ssh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$(dirname "$ROOT")}"
ORG="${STRATA_ORG:-radryc}"
PROTO="${STRATA_PROTO:-https}"

case "$PROTO" in
  https) BASE="https://github.com/$ORG" ;;
  ssh)   BASE="git@github.com:$ORG" ;;
  *)
    printf 'STRATA_PROTO must be "https" or "ssh" (got %q)\n' "$PROTO" >&2
    exit 2
    ;;
esac

if ! command -v git >/dev/null 2>&1; then
  printf 'git is required\n' >&2
  exit 2
fi

mkdir -p "$TARGET"
printf 'Cloning public Strata repositories into %s\n\n' "$TARGET"

while IFS= read -r repo; do
  repo="${repo%%#*}"
  repo="${repo//[[:space:]]/}"
  [[ -n "$repo" ]] || continue

  dest="$TARGET/$repo"

  if [[ -d "$dest/.git" ]]; then
    printf '  = %-10s already cloned\n' "$repo"
    continue
  fi

  if [[ -e "$dest" ]]; then
    printf '  ! %-10s exists but is not a git checkout; skipping\n' "$repo" >&2
    continue
  fi

  printf '  + %-10s cloning\n' "$repo"
  git clone "$BASE/$repo.git" "$dest"
done < "$ROOT/repos.txt"

printf '\nDone.\n\n'
printf 'Next:\n'
printf '  cd %s/monofs && make build && make run-cluster\n' "$TARGET"
printf '  cd %s/guardian && go build ./cmd/guardianctl ./cmd/guardiand\n' "$TARGET"
printf '  cd %s/doctor && make build\n' "$TARGET"
