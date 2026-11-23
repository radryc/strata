# Strata Architecture Documentation

> **Living docs, derived from source.** Every diagram and claim here was checked against the code in this checkout, not inferred from naming alone.
> **Last verified against the source tree:** 2026-11-23.

This directory is the platform-level architecture set for the public Strata repositories. It complements the per-component deep docs (`monofs/docs/architecture.md`, `guardian/docs/architecture.md`, `doctor/docs/architecture/`, …) rather than replacing them: the pages here explain **how the pieces fit together**, and link out for implementation detail.

> **Scope note:** this set documents public repositories only. Private repositories, local-only working directories, and the landing-site repository are intentionally out of scope.

## Document Set

| Document | Covers | Read when |
| --- | --- | --- |
| [platform-overview.md](platform-overview.md) | Five planes, component map, shared contracts, end-to-end flows, topologies, ports, security, failure isolation | You are new to the platform or reviewing a cross-component change. |
| [monofs.md](monofs.md) | Router, storage nodes, HRW, fetcher/archives, FUSE/overlay, session publish, ingestion, OCI registry, search, logengine, pipelines, Guardian/Doctor namespaces | You work on source, storage, workspaces, images, or telemetry persistence. |
| [guardian.md](guardian.md) | Partition/intent/asset compile, DIFF→CHECK→APPLY, queue claims, pushers, drivers, rollouts, access, observed path | You work on deployment, drift, providers, or the Guardian API/UI. |
| [doctor.md](doctor.md) | OTLP ingest, privacy, WAL, MonoFS log-engine, Prometheus/Loki/Tempo APIs, federation, rules, Sentinel | You work on observability, queries, alerting, or telemetry privacy. |
| [agent.md](agent.md) | FastAPI/React stack, route classifier, specialists, 53-tool catalog, approval gate, workspace, Nightwatch, auth | You work on assistance, LLM tooling, approvals, or Nightwatch. |
| [lb-edge.md](lb-edge.md) | Registry state/allocator, proxy reconcile/balance/breaker, k8s agent, edge mode | You work on traffic routing or Kubernetes endpoint exposure. |
| [shared-libraries.md](shared-libraries.md) | `tlsx`, `kvs`, `packager`, `cfg`: TLS/SPIFFE, Raft version chains, encrypted archives, two-tier config | You change a shared library or need its storage/TLS contract. |
| [sql-federation.md](sql-federation.md) | `sqlagregator` catalog/selector/planner/dialects/merge, MonoFS integration, access projection | You work on federated SQL, query policy, or DuckDB. |
| [bootstrap.md](bootstrap.md) | `strata` bootstrap flow, repository map, kind/k8s/AWS modes, reference manifests, build order | You are bootstrapping the platform. |
| [cloud-deployment.md](cloud-deployment.md) | AWS CDK stacks, Guardian GCP pusher path, `k8s-top` metrics exporter | You deploy to AWS/GCP or need cluster resource telemetry. |

## Component Inventory

Every public project covered by this documentation set:

| Project | Type | Plane / role | Document |
| --- | --- | --- | --- |
| `monofs` | Go services + client | Source, storage, registry, search, logengine, pipelines | [monofs.md](monofs.md) |
| `guardian` | Go services + CLI | Deployment control plane | [guardian.md](guardian.md) |
| `doctor` | Go services + React | Observability ingest/query/alerting | [doctor.md](doctor.md) |
| `agent` | Python + React | Assistance plane | [agent.md](agent.md) |
| `lb` | Go services | Traffic plane (lb-edge) | [lb-edge.md](lb-edge.md) |
| `kvs` | Go library | Raft-replicated versioned KV | [shared-libraries.md](shared-libraries.md) |
| `cfg` | Go library | Two-tier versioned config | [shared-libraries.md](shared-libraries.md) |
| `packager` | Go library | Encrypted indexed-tail archives | [shared-libraries.md](shared-libraries.md) |
| `tlsx` | Go library + CLI | TLS/mTLS, SPIFFE, PKI | [shared-libraries.md](shared-libraries.md) |
| `sqlagregator` | Go library + CLI | Federated SQL coordinator | [sql-federation.md](sql-federation.md) |
| `k8s-top` | Go service | Kubernetes metrics → OTLP | [cloud-deployment.md](cloud-deployment.md) |
| `aws` | TypeScript CDK | MonoFS/Guardian/Doctor on ECS Fargate | [cloud-deployment.md](cloud-deployment.md) |
| `strata` | Shell + manifests | Public entry point, bootstrap, docs | [bootstrap.md](bootstrap.md) |

### Not part of the platform

Generated output, local tooling, editor state, and unpublished working directories are intentionally excluded. The set covers the public engine repositories in `strata/repos.txt` (excluding the landing site), plus `sqlagregator`, `tlsx`, and the `strata` entry point.

## Reading Order

1. **[platform-overview.md](platform-overview.md)** — the mental model and shared contracts.
2. **The plane you are changing** — MonoFS → Guardian → Doctor → lb-edge → Agent.
3. **The shared library underneath it** — [shared-libraries.md](shared-libraries.md) or [sql-federation.md](sql-federation.md).
4. **The deployment path** — [bootstrap.md](bootstrap.md) for local/kind, [cloud-deployment.md](cloud-deployment.md) for AWS/GCP.

## Documentation Audit Status

Every living document in the public repositories was reviewed against the code at
the commit below on **2026-11-23**. Historical inventories, design notes, and
audit/remediation snapshots were removed rather than left to drift.

| Repository | Audited commit | Living docs reviewed | Outcome |
| --- | --- | --- | --- |
| `monofs` | `925753a` | README, architecture, logical flows, security, blob layout, DuckDB, admin/session/loadtest READMEs, pipeline docs | Rewritten where stale (gRPC auth, session commit/push, admin flags, pipelines, audit, compaction) |
| `guardian` | `e0a2eee` | README, docs index, architecture, logical flow, codebase map, security, Forge docs | Updated (display profiles, audit anchoring, values/quota, webhook signing, Forge codes, coverage) |
| `doctor` | `c4c6e50` | README, docs index, architecture, logical flows, alerts, incidents, quotas, receivers, security, SQL console, Sentinel spec | Updated (privacy v2 tokens, WAL checkpoints, display/audit, tenant guard, federation, incidents) |
| `agent` | `51f55b6` | README | Updated (test counts, inbound auth, audit emitter, health/metrics) |
| `lb` | `0e8421b` | README, AGENTS | Updated (edge auth behavior, TLS/mTLS, OTLP, port ranges) |
| `kvs` | `ac5de40` | README, versioned-KV architecture | Updated (consumer scope, TLS/audit, purge; target design marked) |
| `cfg` | `a92a364` | README | Updated (consumer scope, `Close`, paths, re-push semantics) |
| `packager` | `bef1399` | README | Updated (plaintext opt-out, envelope API, symlink/traversal) |
| `tlsx` | `8efda85` | README | Updated (reload semantics, CLI flags, `mtls.env`) |
| `k8s-top` | `77d7119` | README | Updated (`otelc` build, initial scrape, `vcs.revision`) |
| `aws` | `6ec6932` | README, `lib/README` | Updated (quick start, encryption key, password policy, teardown, NLB, bind address) |
| `sqlagregator` | `5a682db` | README, DESIGN, PARTITIONING, PARTITION-POLICY, SECURITY | Updated (API/RPC, aggregates, partition binding status, legacy fallback) |
| `strata` | `3dc02cb` | README, docs index, architecture, access/login, AWS, bootstrap, hardening, Kubernetes, local-kind, onboarding, examples, bootstrap docs | Updated (link escapes, quickstarts, OIDC env, separate access repo, image consistency) |

### Verification performed

- **72/72 Mermaid blocks** across all public repos parse.
- **235/235 relative links** across all public repos resolve, plus **77/77** in
  the root documentation set (312 total).
- Each edited document was checked against the referenced flags, types, paths,
  or manifests; `git diff --check` is clean in the touched repos.
- The architecture pages themselves add **28 diagrams** and are part of the
  `strata` count.

### Historical documents removed

Removed on 2026-11-23 because they described older trees or superseded plans:

- `monofs/docs/internal/*` — code inventory, duplication/missing-functionality,
  simplification, remediation decisions.
- `guardian/docs/internal/*` — TODO, changes, duplication, missing, simplification.
- `doctor/docs/internal/*` — TODO, code inventory, duplicate/overcomplexity,
  partition-quota TODO.
- `guardian/docs/design/*` — proposed Forge design, GCP pusher ADR, UI baseline image.
- `docs/security/{FINANCIAL_SECURITY_AUDIT,PHASE3_DESIGN,REMAINING_REMEDIATION}.md`
  — audit and remediation snapshots.
- `docs/authz/EPIC-H-audit-trail.md` — superseded audit-trail plan.
- `docs/design/monofs-alert-ingestion.md` — proposed ingestion design.

Current docs that happen to live under `docs/design/` (for example the Doctor
graph specification) were kept because they explicitly describe HEAD. The
mTLS runbook under `docs/security/` is also kept as an operational runbook.

### Remaining known gaps

These are called out in the component docs rather than silently “fixed”:

- MonoFS `printUsage()` and the client Docker banner still advertise older
  `monofs-admin` flags; the README now documents the real CLI.
- KVS per-key-class retention, object-store archives, sharding, repair, and the
  direct Guardian adapter remain target design.
- SQLAggregator coordinator retries, circuit breaking, `COUNT(DISTINCT)`, and
  the `QuerySpec`/HTTP front door remain unimplemented.
- Doctor privacy-key rotation is supported but manual/environment-only.
- Guardian display-bundle schema beyond the consumed fields is documented at the
  contract level, not as a formal Guardian-side schema.


## How These Docs Stay True

These pages were produced by reading entry points, package layouts, key types, call chains, and deployment manifests, then validating every Mermaid block with the Mermaid parser. They follow the repository's existing terminology; where code and prose disagree, the code wins and the difference is called out under **Notable Details**.

Update these docs when:

- a binary, entry point, or default port changes;
- a new cross-component path, queue convention, or telemetry identity is introduced;
- access scopes or enforcement modes change;
- a deployment topology (kind, k8s, AWS, GCP, compose) gains or loses a component;
- a shared library's on-disk format or version semantics change.

For per-component implementation detail, follow the deep references at the top of each page; those live in the component repositories. This set is self-contained inside the `strata` repository and uses GitHub links for cross-repository references. Source-map paths are **repository-relative**: for example, `monofs/internal/server/...` means that path inside the `monofs` repository, not inside `strata`.
