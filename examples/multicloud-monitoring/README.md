# Multicloud + monitoring deployment example

This directory is a complete, repository-authored Strata deployment. Guardian
reads it as GitOps state instead of relying on shell-generated manifests:

- Platform RBAC and SQL routing live under `access/`.
- Partition desired state, intents, assets, and partition-scoped RBAC live under
  `guardian/partitions/<partition>/`.
- The AWS source of truth is the CDK app under `cdk/`; Guardian observes the
  synthesized CloudFormation stacks.
- `apply.sh` renders the repository, validates it, publishes the policy, and
  injects the partitions into a running Strata/Guardian control plane.

```text
multicloud-monitoring/
├── .guardian/config.yaml              # repo registration + AWS stack bindings
├── access/
│   ├── policy.yaml                    # users, clients, defaults, aws_bindings
│   └── routing/
│       ├── defaults.yaml
│       ├── diva-shared/partition.yaml # AWS Omni + GCP BigQuery + k8s SQL
│       └── divb-shared/partition.yaml # AWS Logs Insights + GCP + k8s
├── app/                               # Node OTel app used by GCP + Kubernetes
├── cdk/                               # AWS CDK app (ECS, ALB, SQS, Lambda, DynamoDB)
├── guardian/partitions/
│   ├── diva-shared/
│   │   ├── config.yaml
│   │   ├── access.yaml                # partition-scoped RBAC
│   │   └── intents/{images,gcp,k8s}.yaml
│   └── divb-shared/
│       ├── config.yaml
│       ├── access.yaml
│       └── intents/{images,gcp,k8s}.yaml
├── apply.sh
└── Makefile
```

The AWS intent is intentionally **not** hand-written. `repo sync` synthesizes
`cdk/`, matches each CloudFormation stack to a partition binding, and writes an
Observed AWS intent/payload into Guardian. This matches the live-stack reality
and avoids committing account-specific CloudFormation output.

## How the injection works

The Strata GitOps contract is:

```text
guardian/partitions/<p>/config.yaml|partition.yaml -> /partitions/<p>/config.yaml
guardian/partitions/<p>/intents/*.yaml              -> /partitions/<p>/intents/
guardian/partitions/<p>/payloads/**                 -> /partitions/<p>/payloads/
guardian/partitions/<p>/access.yaml                 -> /.access/partitions/<p>.yaml
```

`apply.sh` performs these stages:

1. Render `${...}` placeholders into a temporary tree (the repo is never mutated).
2. `guardianctl access lint` and `guardianctl partition validate-local`.
3. Optionally `guardianctl image release` to build/push/stamp the app image.
4. `guardianctl access publish --routing-dir ...` to compile the platform ACL.
5. `guardianctl repo sync --synth` or `repo import` to inject the partitions.
6. Reconcile and print partition status.

## Prerequisites

- A running Guardian with MonoFS and the `k8s-main` pusher.
- An AWS pusher registered in Guardian (`aws-<account>`), and AWS credentials
  with permission to deploy the CDK stacks if you use `--deploy-aws`.
- A GCP pusher (`gcp-<project>`) with permission to deploy Cloud Run.
- `guardianctl`, `envsubst`, Docker, Node.js 20+, and AWS CDK bootstrapped in
  the target account (`npx cdk bootstrap`).
- A registry reachable by the Kubernetes and GCP pushers. The default is the
  local kind registry `registry.strata.local:5000`.

## Quick start (local kind)

```bash
export AWS_ACCOUNT_A=123456789012
export AWS_ACCOUNT_B=$AWS_ACCOUNT_A        # split accounts into separate repos if needed
export AWS_REGION=us-east-1
export GCP_PROJECT=strata-gcp-dev
export GCP_REGION=europe-west1

export MONOFS_ROUTER=127.0.0.1:19090
export MONOFS_TOKEN="$(kubectl -n strata get secret strata-secrets \
  -o jsonpath='{.data.MONOFS_TOKEN}' | base64 -d)"

# Validate without touching the control plane
./apply.sh --validate-only

# Build/stamp the app image, deploy AWS, publish policy, import + observe
./apply.sh --deploy-aws
```

If the AWS stacks are already deployed, omit `--deploy-aws`; Guardian will
observe them from the synthesized assembly.

If you only want the Kubernetes and GCP halves:

```bash
./apply.sh --skip-aws
```

## Environment

| Variable | Purpose | Default |
|---|---|---|
| `AWS_ACCOUNT_A` / `AWS_ACCOUNT_B` | AWS accounts for DivA / DivB | required / A |
| `AWS_REGION` | AWS region | `us-east-1` |
| `GCP_PROJECT` / `GCP_REGION` | GCP project and region | required / `europe-west1` |
| `GCP_PUSHER` | Guardian GCP pusher | `gcp-<project>` |
| `K8S_PUSHER` / `K8S_CLUSTER` | Kubernetes pusher and cluster | `k8s-main` |
| `K8S_NAMESPACE` | Namespace for both apps | `div-demo` |
| `IMAGE_REGISTRY` | Registry for the app image | `registry.strata.local:5000` |
| `OTLP_ENDPOINT` / `OTLP_HEADERS` | OTLP exporter for the k8s app | in-cluster collector |
| `GCP_URL_A` / `GCP_URL_B` | Cloud Run URLs (cross-provider traces) | empty |
| `AWS_URL_A` / `AWS_URL_B` | ALB URLs (cross-provider traces) | empty |
| `ASSUME_ROLE` | Role assumed in member accounts for routing | `OrganizationAccountAccessRole` |
| `BQ_DATASET_DIVA` / `BQ_DATASET_DIVB` | BigQuery datasets | `strata_logs_*_shared` |
| `MONOFS_ROUTER` / `MONOFS_TOKEN` | Direct MonoFS connection | — |
| `GUARDIAN_URL` | Guardian UI/API connection | — |
| `REPO_SOURCE` | Repo URL recorded in Guardian | this directory |

Do not commit credentials. The CDK app and intents contain no secrets; use
`Secret` assets with `secretRef` for runtime secrets.

## Cross-provider traces

The three applications form two trace paths:

```text
k8s -> GCP Cloud Run -> AWS ALB/ECS
k8s -> AWS ALB/ECS -> GCP Cloud Run
```

The URLs are deployment outputs. After the first apply:

```bash
# GCP out of the gcp intent outputs, AWS out of the stack outputs
guardianctl intent outputs --partition diva-shared --intent gcp
aws cloudformation describe-stacks --stack-name DivASharedStack \
  --query 'Stacks[0].Outputs'
```

Set `GCP_URL_A`/`AWS_URL_A` (and B) and re-run `./apply.sh` to update the k8s
and GCP env. The apps still deploy and report telemetry without them, but the
cross-provider trace direction needs both URLs.

## Monitoring

The platform monitoring bundle remains the canonical Grafana/Prometheus/OTel
stack: `stratatools/partitions/monitoring`. That bundle lives in the separate
`stratatools` repository, which `scripts/clone.sh` does not clone. Clone it as a
sibling of the `strata` checkout first (from the directory that contains
`strata/`):

```bash
git clone <stratatools-remote> stratatools
```

Apply it after the control plane and the partitions above. See
[`monitoring/README.md`](monitoring/README.md) for prerequisites and the
monitoring-specific apply commands.

```bash
cd ../../../guardian
./bin/guardianctl release run --partition monitoring --build --bump
```

The dashboards in that bundle include the cross-provider division boards (AWS
CloudWatch/X-Ray, GCP Cloud Run, and Kubernetes) and the platform health boards.
The `access/routing/*/partition.yaml` files in this example define the SQL/log
shards those dashboards and Doctor query.

## Verify

```bash
guardianctl partition list
guardianctl partition status --partition diva-shared
guardianctl partition assignments --partition diva-shared
guardianctl intent status --partition diva-shared --intent gcp
guardianctl intent status --partition diva-shared --intent k8s
# apply.sh prints these after applying; for a rendered tree use --raw
guardianctl access explain --raw <rendered>/access/policy.yaml --user usera@example.com
```

Expected RBAC:

- `usera@example.com` sees `diva-shared` only.
- `userb@example.com` sees `divb-shared` only.
- `admin@example.com` sees the monitoring/platform partitions, never the other
  division's logs/traces.

## GitOps loop

Once this repository is ingested by MonoFS, Guardian's repo-import loop reads
`/.repos/**/guardian/partitions/**` and imports changed bundles automatically.
`apply.sh` is the explicit, one-shot path for local development and CI. In CI,
run the same steps with a service token; do not use a human SSO session.

```yaml
# .github/workflows/strata-deploy.yml (sketch)
- run: ./apply.sh --skip-aws
  env:
    MONOFS_ROUTER: ${{ secrets.MONOFS_ROUTER }}
    MONOFS_TOKEN: ${{ secrets.MONOFS_TOKEN }}
    GCP_PROJECT: ${{ vars.GCP_PROJECT }}
    AWS_ACCOUNT_A: ${{ vars.AWS_ACCOUNT_A }}
```

## Troubleshooting

- `access lint` fails on a partition name: the `partition` in `access.yaml` must
  match its directory and the partition manifest.
- `repo sync` cannot find a pusher: register `aws-<account>` first, or use
  `--skip-aws` and apply the GCP/k8s stacks only.
- `image release` cannot push: `docker login` to `IMAGE_REGISTRY`, or pass
  `--skip-images` after stamping the intents in CI.
- Kubernetes pods are `ImagePullBackOff`: load the image into kind or configure
  the kind registry (`guardianctl dev configure-registry`).
