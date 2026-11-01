#!/usr/bin/env bash
# Deploy the Strata control plane to AWS with the public CDK project.
#
# Usage:
#   ./scripts/aws-up.sh [deploy.sh flags]
#
# Common examples:
#   AWS_PROFILE=prod AWS_REGION=eu-west-1 ./scripts/aws-up.sh -y
#   ./scripts/aws-up.sh --with-pusher --with-demo -y
#
# The CDK project lives in the sibling `aws` checkout. It builds MonoFS,
# Guardian, and Doctor images from pinned public source revisions, so no
# sibling source tree is required for the image build itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_DIR="${STRATA_AWS_DIR:-$ROOT/../aws}"

[[ -d "$AWS_DIR" ]] || {
  printf 'error: AWS CDK checkout not found at %s\n' "$AWS_DIR" >&2
  printf 'Run scripts/clone.sh from the Strata repo first.\n' >&2
  exit 1
}
[[ -x "$AWS_DIR/deploy.sh" ]] || {
  printf 'error: %s/deploy.sh is missing or not executable\n' "$AWS_DIR" >&2
  exit 1
}

cd "$AWS_DIR"
exec ./deploy.sh "$@"
