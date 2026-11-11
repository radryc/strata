# Strata repository architecture

This repository is the public entry point for the Strata platform. It does not
contain the engines; it contains the bootstrap scripts, reference manifests,
examples, and the documentation that ties the component repositories together.

## Scope

| In this repository | In the component repositories |
|---|---|
| Bootstrap and teardown scripts for kind, Kubernetes, and AWS | MonoFS, Guardian, Doctor, LB, Agent, KVS, CFG, Packager, k8s-top, AWS CDK, Hub |
| Reference Kubernetes manifests under `bootstrap/k8s/` | Guardian partition definitions owned by each component |
| A prepared application partition under `bootstrap/partitions/` | Runtime images and binaries |
| Public documentation under `docs/` | Component architecture, security, and operating guides |
| `repos.txt` build order and the `clone.sh` helper | — |

## Repository layout

```text
bootstrap/
  kind/cluster.yaml          kind cluster definition
  k8s/                       reference control-plane manifests
  partitions/                prepared application partitions
  auth/                      development Authentik SSO reference
examples/
  aws-app/                   sample application for the AWS deployment
  onboarding-app/            sample application for the onboarding flow
scripts/
  clone.sh                   clone component repositories as siblings
  dev-kind-up.sh             build images, create kind cluster, bootstrap
  k8s-up.sh                  build/push images and deploy to a cluster
  aws-up.sh                  deploy the AWS CDK stack
  onboard-app.sh             onboard an application repository
docs/                        operator guides and this architecture document
repos.txt                    component repositories in build order
```

## Platform topology

The bootstrap deploys five planes. Each plane is one or more component
repositories:

```mermaid
flowchart TB
    subgraph Bootstrap[This repository]
        SCRIPTS[scripts/*.sh]
        MANIFESTS[bootstrap/k8s]
        PARTITIONS[bootstrap/partitions]
    end

    subgraph Core[Core planes]
        MONOFS[MonoFS<br/>source + state + telemetry]
        GUARDIAN[Guardian<br/>compile / reconcile / apply]
        DOCTOR[Doctor<br/>OTLP / privacy / query]
        LB[lb<br/>registry + TCP proxy]
        AGENT[Agent<br/>tools + approval gates]
    end

    SCRIPTS --> MANIFESTS
    SCRIPTS --> PARTITIONS
    MANIFESTS --> MONOFS
    MANIFESTS --> GUARDIAN
    MANIFESTS --> DOCTOR
    PARTITIONS -->|guardianctl push| GUARDIAN
    GUARDIAN -->|DIFF / CHECK / APPLY| MONOFS
    GUARDIAN -->|assets| DOCTOR
    DOCTOR -->|telemetry chunks| MONOFS
    LB -->|routes| MONOFS
    AGENT -->|reads| MONOFS
    AGENT -->|reads/writes| GUARDIAN
    AGENT -->|reads| DOCTOR
```

`bootstrap/k8s` starts MonoFS, Guardian, and Doctor directly. The component
partitions under each engine repository are then ingested into MonoFS and
imported by Guardian; they observe the bootstrap workloads and add probes
instead of creating duplicate deployments.

## Bootstrap flow

1. `scripts/clone.sh` reads `repos.txt` and clones each component as a sibling
   directory. The Go `replace` directives in MonoFS, Guardian, Doctor, and CFG
   expect this layout.
2. `scripts/dev-kind-up.sh` builds the images, creates the kind cluster, applies
   `bootstrap/kind/cluster.yaml` and `bootstrap/k8s/`, then ingests the
   component repositories and imports their partitions.
3. `scripts/k8s-up.sh` repeats the deployment against the current kubeconfig;
   `ARGS` are forwarded to the helper for image prefixes, tags, and namespaces.
4. `scripts/onboard-app.sh` renders an application partition from
   `bootstrap/partitions/onboarding-app/` and pushes it with `guardianctl`.
5. `scripts/aws-up.sh` deploys the AWS CDK stack from the `aws` repository.

The checked-in manifests use the `strata` namespace and the placeholders
`__APP_IMAGE__`, `__IMAGE_PREFIX__`, `__IMAGE_TAG__`, and `__NAMESPACE__`.
Scripts render them into `.strata/`; the checked-in files are not modified.

## Component responsibilities

| Repository | Responsibility |
|---|---|
| `monofs` | Distributed filesystem, Git workspace, source/state/log-engine plane |
| `guardian` | Declarative deployment control plane: partitions, intents, typed assets, reconciliation, drift |
| `doctor` | Privacy-first telemetry backend: OTLP ingest, HMAC tokenization, trace/log/metric query, alerts |
| `lb` | L4 registry and TCP proxy (LB-Edge) |
| `agent` | Assistance plane: platform questions, incident investigation, approval-gated changes |
| `kvs` | Raft-replicated versioned KV backing Guardian and MonoFS state |
| `cfg` | Two-tier versioned config store over KVS and packager |
| `packager` | Encrypted, compressed object-store archives with random access |
| `k8s-top` | Kubernetes pod/container metrics exporter with Guardian identity labels |
| `aws` | CDK project deploying MonoFS and Guardian to ECS Fargate |
| `hub` | Static landing page for stratasre.com |

## Versioning and release model

Each component repository is versioned independently with semantic tags
(`vMAJOR.MINOR.PATCH`) and a GitHub release. `repos.txt` lists the recommended
build order, not a lockstep version set. The bootstrap pulls component source
at build time, so a deployment is reproducible from the clones created by
`clone.sh`.

## Related documentation

- [Local kind stack](local-kind.md)
- [Kubernetes deployment](kubernetes.md)
- [AWS deployment](aws.md)
- [Access and login](access-and-login.md)
- [Application onboarding](onboarding-application.md)
- [Prepared bootstrap partition](bootstrap-partition.md)
