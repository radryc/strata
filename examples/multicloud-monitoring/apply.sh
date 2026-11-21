#!/usr/bin/env bash
# Render this repository's GitOps bundle, validate it, publish the policy, and
# inject the partitions into Strata through guardianctl.
#
# The repository is the source of truth:
#   access/policy.yaml + access/routing/**       platform RBAC + SQL routing
#   guardian/partitions/<p>/config.yaml          partition desired state
#   guardian/partitions/<p>/intents/*.yaml       GCP / k8s / image intents
#   guardian/partitions/<p>/access.yaml          partition-scoped RBAC
#   cdk/                                         AWS source (observed by Guardian)
#
# AWS assets are observed from the CDK assembly; they are not hand-authored.
set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRATA_ROOT="$(cd "$EXAMPLE_DIR/../../.." && pwd)"

VALIDATE_ONLY=false
SKIP_IMAGES=false
DEPLOY_AWS=false
SKIP_AWS=false
RECONCILE=true

usage() {
  cat <<'EOF'
Usage: ./apply.sh [options]

Options:
  --validate-only     Render and validate only; do not publish/import
  --skip-images       Do not run `guardianctl image release` (use pre-stamped image refs)
  --deploy-aws        Run `npx cdk deploy --all` before observing (needs AWS credentials)
  --skip-aws          Do not register/observe the CDK repo (GCP + k8s only)
  --no-reconcile      Import partitions without triggering a reconcile
  --guardian-url URL  Guardian UI/API URL (default: $GUARDIAN_URL)
  --monofs-router A   MonoFS router gRPC address (default: $MONOFS_ROUTER)
  --monofs-token T    MonoFS guardian token (default: $MONOFS_TOKEN)
  --repo-source URL   Repo URL to record (default: $REPO_SOURCE or this directory)
  -h, --help          Show this help

Environment:
  AWS_ACCOUNT_A / AWS_ACCOUNT_B   AWS account ids (B defaults to A)
  AWS_REGION                      AWS region (default us-east-1)
  GCP_PROJECT / GCP_REGION        GCP project and region
  GCP_PUSHER                      GCP pusher name (default gcp-<project>)
  K8S_PUSHER / K8S_CLUSTER        Kubernetes pusher (default k8s-main)
  K8S_NAMESPACE                   Kubernetes namespace (default div-demo)
  IMAGE_REGISTRY                  Registry for the app image (default registry.strata.local:5000)
  OTLP_ENDPOINT / OTLP_HEADERS   Kubernetes OTLP exporter settings
  GCP_URL_A / GCP_URL_B           Cloud Run URLs (fill after GCP apply for cross-provider traces)
  AWS_URL_A / AWS_URL_B           ALB URLs (fill after AWS deploy for cross-provider traces)
  GUARDIANCTL                     guardianctl binary (default: PATH or ../../guardian/bin/guardianctl)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --skip-images) SKIP_IMAGES=true; shift ;;
    --deploy-aws) DEPLOY_AWS=true; shift ;;
    --skip-aws) SKIP_AWS=true; shift ;;
    --no-reconcile) RECONCILE=false; shift ;;
    --guardian-url) GUARDIAN_URL="${2:?--guardian-url requires a value}"; shift 2 ;;
    --monofs-router) MONOFS_ROUTER="${2:?--monofs-router requires a value}"; shift 2 ;;
    --monofs-token) MONOFS_TOKEN="${2:?--monofs-token requires a value}"; shift 2 ;;
    --repo-source) REPO_SOURCE="${2:?--repo-source requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

AWS_ACCOUNT_A="${AWS_ACCOUNT_A:-}"
AWS_ACCOUNT_B="${AWS_ACCOUNT_B:-$AWS_ACCOUNT_A}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_REGION="${GCP_REGION:-europe-west1}"
K8S_PUSHER="${K8S_PUSHER:-k8s-main}"
K8S_CLUSTER="${K8S_CLUSTER:-k8s-main}"
K8S_NAMESPACE="${K8S_NAMESPACE:-div-demo}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.strata.local:5000}"
OTLP_ENDPOINT="${OTLP_ENDPOINT:-http://k8s-svc-compute-k8s-main-otel-opentelemetry-collector-collector.otel.svc.cluster.local:4318}"
OTLP_HEADERS="${OTLP_HEADERS:-}"
GCP_URL_A="${GCP_URL_A:-}"
GCP_URL_B="${GCP_URL_B:-}"
AWS_URL_A="${AWS_URL_A:-}"
AWS_URL_B="${AWS_URL_B:-}"
ASSUME_ROLE="${ASSUME_ROLE:-OrganizationAccountAccessRole}"
BQ_DATASET_DIVA="${BQ_DATASET_DIVA:-strata_logs_diva_shared}"
BQ_DATASET_DIVB="${BQ_DATASET_DIVB:-strata_logs_divb_shared}"
K8S_SQL_PLACEMENT_ID="${K8S_SQL_PLACEMENT_ID:-clickhouse}"
K8S_SQL_BACKEND="${K8S_SQL_BACKEND:-clickhouse}"
K8S_SQL_SOURCE="${K8S_SQL_SOURCE:-strata.logs}"
K8S_SQL_BINDING="${K8S_SQL_BINDING:-}"
if [[ -z "$K8S_SQL_BINDING" ]]; then
  K8S_SQL_BINDING='{kind: attribute, path: ["labels", "guardian.partition"]}'
fi
ACCESS_ENV="${ACCESS_ENV:-dev}"
REPO_NAME="${REPO_NAME:-multicloud-monitoring}"

if [[ -z "$GCP_PROJECT" ]]; then
  echo "GCP_PROJECT is required (export GCP_PROJECT=...)"; exit 2
fi
if [[ -z "$AWS_ACCOUNT_A" ]]; then
  echo "AWS_ACCOUNT_A is required (export AWS_ACCOUNT_A=...)"; exit 2
fi
GCP_PUSHER="${GCP_PUSHER:-gcp-$(printf '%s' "$GCP_PROJECT" | tr '[:upper:].' '[:lower:]-')}"

REPO_SOURCE="${REPO_SOURCE:-$EXAMPLE_DIR}"
repo_base="$(basename "${REPO_SOURCE%/}")"
repo_base="${repo_base%.git}"
if [[ "$REPO_SOURCE" =~ ^[a-z]+:// ]] || [[ "$REPO_SOURCE" =~ ^git@ ]]; then
  repo_host="$(printf '%s' "$REPO_SOURCE" | sed -E 's#^[a-z]+://##; s#^git@##; s#[:/].*##')"
  MONOFS_REPO_PATTERN="${repo_host}/*/${repo_base}"
else
  MONOFS_REPO_PATTERN="$repo_base"
fi

if [[ -n "${GUARDIANCTL:-}" ]]; then
  :
elif command -v guardianctl >/dev/null 2>&1; then
  GUARDIANCTL="$(command -v guardianctl)"
elif [[ -x "$STRATA_ROOT/guardian/bin/guardianctl" ]]; then
  GUARDIANCTL="$STRATA_ROOT/guardian/bin/guardianctl"
else
  echo "guardianctl not found; build it with: (cd $STRATA_ROOT/guardian && go build -o bin/guardianctl ./cmd/guardianctl)" >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is required (install gettext)" >&2
  exit 1
fi

declare -a CONNECT=()
if [[ -n "${MONOFS_ROUTER:-}" ]]; then
  CONNECT+=(--monofs-router "$MONOFS_ROUTER")
  [[ -n "${MONOFS_TOKEN:-}" ]] && CONNECT+=(--monofs-token "$MONOFS_TOKEN")
elif [[ -n "${GUARDIAN_URL:-}" ]]; then
  CONNECT+=(--guardian-url "$GUARDIAN_URL")
elif [[ "$VALIDATE_ONLY" != true ]]; then
  echo "set MONOFS_ROUTER/MONOFS_TOKEN or GUARDIAN_URL (or use --validate-only)" >&2
  exit 2
fi

export AWS_ACCOUNT_A AWS_ACCOUNT_B AWS_REGION GCP_PROJECT GCP_REGION GCP_PUSHER
export K8S_PUSHER K8S_CLUSTER K8S_NAMESPACE IMAGE_REGISTRY OTLP_ENDPOINT OTLP_HEADERS
export GCP_URL_A GCP_URL_B AWS_URL_A AWS_URL_B REPO_SOURCE MONOFS_REPO_PATTERN
export ASSUME_ROLE BQ_DATASET_DIVA BQ_DATASET_DIVB ACCESS_ENV
export K8S_SQL_PLACEMENT_ID K8S_SQL_BACKEND K8S_SQL_SOURCE K8S_SQL_BINDING
APP_BUILD_CONTEXT="${APP_BUILD_CONTEXT:-app}"
export APP_BUILD_CONTEXT

# The CDK app reads these directly; keep the AWS -> GCP trace target and repo
# tag aligned with the rest of the example.
export GUARDIAN_REPO_A="${GUARDIAN_REPO_A:-$REPO_SOURCE}"
export GUARDIAN_REPO_B="${GUARDIAN_REPO_B:-$REPO_SOURCE}"
export AWS_DOWNSTREAM_URL_A="${AWS_DOWNSTREAM_URL_A:-$GCP_URL_A}"
export AWS_DOWNSTREAM_URL_B="${AWS_DOWNSTREAM_URL_B:-$GCP_URL_B}"
export STRATA_OTLP_ENDPOINT="${STRATA_OTLP_ENDPOINT:-$OTLP_ENDPOINT}"
export STRATA_OTLP_LAMBDA_ENDPOINT="${STRATA_OTLP_LAMBDA_ENDPOINT:-}"
export STRATA_OTLP_TOKEN="${STRATA_OTLP_TOKEN:-}"
export STRATA_OTLP_LATTICE_SERVICE_NETWORK_ARN="${STRATA_OTLP_LATTICE_SERVICE_NETWORK_ARN:-}"

VARS='${AWS_ACCOUNT_A} ${AWS_ACCOUNT_B} ${AWS_REGION} ${GCP_PROJECT} ${GCP_REGION} ${GCP_PUSHER} ${K8S_PUSHER} ${K8S_CLUSTER} ${K8S_NAMESPACE} ${IMAGE_REGISTRY} ${OTLP_ENDPOINT} ${OTLP_HEADERS} ${GCP_URL_A} ${GCP_URL_B} ${AWS_URL_A} ${AWS_URL_B} ${REPO_SOURCE} ${MONOFS_REPO_PATTERN} ${ASSUME_ROLE} ${BQ_DATASET_DIVA} ${BQ_DATASET_DIVB} ${K8S_SQL_PLACEMENT_ID} ${K8S_SQL_BACKEND} ${K8S_SQL_SOURCE} ${K8S_SQL_BINDING} ${APP_BUILD_CONTEXT}'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/strata-multicloud.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cp -a "$EXAMPLE_DIR/.guardian" "$TMP/.guardian"
cp -a "$EXAMPLE_DIR/guardian" "$TMP/guardian"
cp -a "$EXAMPLE_DIR/access" "$TMP/access"
# repo sync needs the CDK app and its asset source in the rendered tree.
cp -a "$EXAMPLE_DIR/cdk" "$TMP/cdk"
cp -a "$EXAMPLE_DIR/app" "$TMP/app"
rm -rf "$TMP/cdk/node_modules" "$TMP/cdk/cdk.out" "$TMP/app/node_modules"

while IFS= read -r -d '' file; do
  envsubst "$VARS" <"$file" >"$file.tmp"
  mv "$file.tmp" "$file"
done < <(find "$TMP" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

echo "==> validating rendered policy and partition manifests"
"$GUARDIANCTL" access lint --file "$TMP/access/policy.yaml"
"$GUARDIANCTL" partition validate-local -root "$TMP/guardian/partitions"

if $VALIDATE_ONLY; then
  echo "render + validation passed (temporary tree: $TMP)"
  trap - EXIT
  echo "kept rendered tree at $TMP"
  exit 0
fi

if ! $SKIP_IMAGES; then
  echo "==> building and stamping the application image"
  for partition in diva-shared divb-shared; do
    (
      cd "$EXAMPLE_DIR"
      "$GUARDIANCTL" image release --dir "$TMP/guardian/partitions/$partition" --registry "$IMAGE_REGISTRY"
    )
  done
fi

echo "==> publishing access policy and routing"
"$GUARDIANCTL" "${CONNECT[@]}" access publish \
  --file "$TMP/access/policy.yaml" \
  --env "$ACCESS_ENV" \
  --routing-dir "$TMP/access/routing"

if $DEPLOY_AWS; then
  echo "==> deploying AWS CDK stacks (requires AWS credentials)"
  (
    cd "$TMP/cdk"
    npm install --silent --no-audit --no-fund
    npx cdk deploy --all --require-approval never
  )
fi

if $SKIP_AWS; then
  echo "==> importing authored partitions (AWS observation skipped)"
  "$GUARDIANCTL" "${CONNECT[@]}" repo import \
    --name "$REPO_NAME" \
    --source "$TMP" \
    --reconcile="$RECONCILE"
else
  echo "==> importing partitions and observing the AWS CDK assembly"
  "$GUARDIANCTL" "${CONNECT[@]}" repo sync \
    --dir "$TMP" \
    --synth \
    --reconcile="$RECONCILE"
fi

echo "==> partition status"
"$GUARDIANCTL" "${CONNECT[@]}" partition status --partition diva-shared || true
"$GUARDIANCTL" "${CONNECT[@]}" partition status --partition divb-shared || true

echo "==> RBAC explain"
for user in usera@example.com userb@example.com admin@example.com; do
  echo "-- $user"
  "$GUARDIANCTL" access explain --raw "$TMP/access/policy.yaml" --user "$user" || true
done

cat <<EOF

Applied. Useful next steps:
  guardianctl partition assignments --partition diva-shared
  guardianctl access explain --user usera@example.com
  kubectl -n ${K8S_NAMESPACE} get deploy,svc,pods -l guardian.partition=diva-shared

For the platform monitoring bundle:
  (cd ${STRATA_ROOT}/guardian && ./bin/guardianctl release run --partition monitoring --build --bump)
EOF
