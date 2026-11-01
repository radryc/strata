# Production Gap Remediation Plan

Status: in progress  
Date: 2026-11-01  
Scope: `guardian/TODO.md`, `doctor/TODO.md`, `demo/TODO.md`, and the inline
developer TODO in `guardian/cmd/guardianctl/bootstrap.go`.

This plan closes every open item in those backlogs. It is ordered so that
security and data-integrity blockers land before scale and refactoring work.
Each item lists the implementation approach, the files that change, the tests
that must pass, and the definition of done.

## Operating rules

1. **No item is marked done until code, tests, and docs agree.** Partial work is
   marked `[~]`, not `[x]`.
2. **Safe defaults win.** A new setting defaults to the secure behaviour; a
   development escape hatch must be explicit, logged, and documented.
3. **No plaintext secrets in new paths.** Tests assert that secret values do not
   appear in queue files, state files, results, archives, or logs.
4. **Every external input is bounded.** URLs, bodies, fan-out, response sizes,
   and retries have explicit limits.
5. **Backwards compatibility is a feature.** Existing deployments get a
   migration path and a deprecation window; removals are called out in the
   release notes.
6. **One test suite per wave.** The wave is not complete until the repo test
   command, `go vet`, and the frontend build pass.

## Verification commands

Guardian:

```bash
cd guardian
go test ./cmd/... ./internal/... ./pkg/...
go vet ./cmd/... ./internal/... ./pkg/...
npm run build:ui
```

Doctor:

```bash
cd doctor
go test ./...
go vet ./...
npm --prefix frontend run build
```

Demo:

```bash
cd demo
./demo.sh doctor
./demo.sh test --scenario core
```

Load/scale items additionally run `make loadtest-federation`.

---

## Phase 0 — backlog truth-up and completed-item removal

**Goal:** make the TODO files trustworthy before adding more work.

- [x] Remove the completed Demo items from `demo/TODO.md`: S3 drift fix,
      `wipe_aws.sh` hardening, per-intent role cleanup, UI badges.
- [x] Replace the rest of `demo/TODO.md` with one remaining acceptance item:
      run the clean end-to-end suite after the current changes.
- [x] Remove the duplicate `doctor/TODO.md` copy from the
      `.sentinel-worktrees/doctor-merged` worktree; the canonical file is the
      repo root one.
- [x] Add a short status line to each remaining item so a checkbox means
      “verified done”, not “someone once wrote this down”.
- [x] Move the inline `dev setup --repos-dir` gap into the Guardian backlog
      (P2, developer experience) instead of leaving an untracked comment.

**Exit criteria:** every open checkbox describes work that is still real; every
removed item has a commit/test/doc reference.

---

## Phase 1 — Guardian safe defaults (P0 security)

### 1.1 UI authentication, CSRF, and browser headers — Guardian item 2

**Approach**

- Add `Options.RequireAuthentication`, `Options.TrustedOrigins`, and
  `Options.EnableHSTS`.
- Wrap the UI handler in two middlewares:
  - `securityHeaders`: CSP (`default-src 'self'`; inline styles/scripts only
    where the existing theme bootstrap requires them), `X-Content-Type-Options`,
    `X-Frame-Options`/`frame-ancestors`, `Referrer-Policy`,
    `Permissions-Policy`, and HSTS when TLS terminates at Guardian.
  - `mutationGuard`: reject anonymous non-GET/HEAD/OPTIONS requests when
    authentication is required; validate `Origin`/`Referer` for cookie-backed
    browser mutations; allow bearer-authenticated API clients.
- Wire `GUARDIAN_REQUIRE_UI_AUTH` (default: true when OIDC or the access policy
  is configured, false only for explicit local development),
  `GUARDIAN_TRUSTED_ORIGINS`, and `GUARDIAN_ENABLE_HSTS`.
- Keep loopback-only development usable, but log a loud warning when anonymous
  mutations are allowed.
- Document the migration in `guardian/docs/` and the UI README.

**Files:** `cmd/guardiand/main.go`, `internal/ui/server.go`,
`internal/ui/templates/index.html`, `internal/ui/static-src/index.html`,
`internal/ui/*_test.go`.

**Tests:** anonymous mutation rejected; loopback development allowed when
explicitly enabled; cross-origin cookie mutation rejected; same-origin accepted;
bearer API mutation accepted; headers present; HSTS only behind TLS.

**Definition of done:** no anonymous mutation path remains in the default
production configuration.

### 1.2 Reference-only secrets — Guardian item 3

**Approach**

- Make `secretRef` the preferred form. Reject inline `properties.value` for
  Secret assets when `GUARDIAN_REQUIRE_SECRET_REFS=true` (default in shared
  deployments; explicit dev opt-out).
- Resolve refs only inside the pusher, immediately before use. Never write the
  resolved value into task specs, results, state, archive, or logs.
- Docker: mount a secret file or use a runtime secret mechanism instead of
  `-e KEY=VALUE`; fall back only with an explicit insecure flag.
- Kubernetes: create/use a `Secret` plus `secretKeyRef`; support
  `imagePullSecrets`; never put values in deployment env.
- Secret outputs: hashes or refs only.
- Add a redaction test that scans queue/state/result/archive artifacts.

**Files:** `internal/domain/assets/secret.go`, `internal/pusher/secrets/`,
`internal/pusher/drivers/{docker,kubernetes,aws}/`,
`internal/compiler/planner/`, `cmd/guardianctl/partition_push.go`.

**Tests:** inline value rejected in strict mode; ref resolved at apply time;
no plaintext in artifacts; Docker/Kubernetes render secret refs; existing dev
bundles still load with the escape hatch.

### 1.3 AWS read API hardening — Guardian item 4

**Approach**

- Add TLS/mTLS listener flags and server timeouts.
- Require authentication for non-loopback binds; add scoped tokens
  (`read`, `diff`, `admin`) with rotation via a token file.
- Add per-caller rate limits and request/response size limits.
- Disable `/v1/aws/observed/diff` by default; require the `diff` scope and the
  explicit `--enable-observed-diff` flag.
- Add audit-style logs for auth failures and diff runs.

**Files:** `cmd/guardian-pusher-aws/main.go`, `internal/awsread/handler.go`,
`internal/awsobserve/diff.go`, `internal/pusher/drivers/aws/synth.go`.

**Tests:** unauthenticated, wrong-scope, oversized, rate-limited, diff-disabled,
and TLS round-trip.

### 1.4 IAM least privilege — Guardian item 5

**Approach**

- Require `ExternalId` in the bootstrap trust policy and add
  `aws:SourceAccount`/`aws:SourceArn` conditions.
- Replace broad `Resource: "*"` statements with resource-scoped policies where
  the template catalog declares ARNs; keep documented break-glass statements
  for services that do not support resource scoping.
- Attach a permissions boundary and remove `iam:CreateRole`/`PassRole` from
  per-intent roles unless the template explicitly needs them.
- Stop exporting static AWS credentials to `npm`/CDK child processes; use the
  assumed-role environment.
- `aws setup` validates that the role can actually be assumed.

**Files:** `internal/awssetup/{iam,policy}.go`,
`internal/pusher/drivers/aws/{execution_role,cli_backend}.go`,
`cmd/guardianctl/aws.go`.

**Tests:** policy snapshots, trust-policy validation, role-assumption check,
no `*` secrets/IAM grants in generated policies.

### 1.5 Task archive retention and integrity — Guardian item 6

**Approach**

- Add `GUARDIAN_TASK_ARCHIVE_RETENTION` (count and/or duration).
- Prune old specs before writing a new one; never touch the live queue.
- Hash-chain archive records and publish the chain head to compliance storage.
- Expose archive age/count metrics.

**Files:** `internal/orchestrator/dispatcher/dispatcher.go`,
`internal/paths/paths.go`, `internal/compliance/publisher.go`.

**Tests:** retention by count and age; live queue untouched; chain verifies;
corrupt chain fails closed.

### 1.6 Build and release hardening — Guardian item 13

**Approach**

- Add non-root users, read-only root filesystems, dropped capabilities, and
  explicit state/socket mounts to all four images.
- Add the missing `guardian-up`, `guardian-down`, and `guardian-logs` Makefile
  targets (or remove them from help).
- CI builds images, generates SBOMs, scans vulnerabilities, signs artifacts,
  and runs `go test` + `go vet`.
- Delete the `drop-go-sum-on-release` workflow; keep `go.sum` committed.
- Set version/commit/build-time labels consistently.

**Files:** `Dockerfile*`, `Makefile`, `.github/workflows/*`, `internal/buildinfo/`.

**Tests:** image smoke test as non-root; `make` targets; CI workflow lint;
release build preserves `go.sum`.

### 1.7 Probe history and failure limits — Guardian item 14

**Approach**

- Store bounded probe history (ring buffer/time window) alongside the latest
  snapshot.
- Guard storeless mode with a nil-safe store.
- Reuse HTTP transports and close them on shutdown.
- Add per-target error budgets/circuit breakers and document them.

**Files:** `internal/pusher/probes/`, `internal/observed/`, `cmd/guardiand/main.go`.

**Tests:** storeless mode, history bounds, transport reuse, circuit-breaker
open/half-open/close.

---

## Phase 2 — Guardian reliability and scale (P0/P1)

### 2.1 Leader election and CAS — Guardian item 1

**Approach**

- Reuse the `repowatch` Kubernetes lease elector for a global control-plane
  leader (or per-shard leaders), with a configurable lease name and duration.
- Wrap reconciler, result processor, observed collector, alert evaluator, and
  onboarding loops in the elected leader context.
- Add expected-version writes to `WriteIntentState`, `WritePartitionState`, and
  `WriteRelease`; conflicts retry with a fresh read or return a typed conflict.
- Add a two-replica integration test using the memory/FS store and a fake
  elector.

**Files:** `cmd/guardiand/main.go`, `internal/orchestrator/reconciler/`,
`internal/orchestrator/dispatcher/`, `internal/orchestrator/results/`,
`internal/alerting/`, `internal/observed/`, `internal/onboard/`.

**Tests:** only one leader reconciles; failover within one lease interval;
concurrent writes do not double-queue/archive; CAS conflict is retried/aborted.

### 2.2 Native AWS resource decision — Guardian item 7

**Decision:** mark the incomplete native drivers experimental and require
`implementation: cdk` for Aurora, EFS, Network, LoadBalancer, and S3 features
that are not fully implemented. This is the acceptance path explicitly allowed
by the TODO.

**Approach**

- Add validation warnings/errors for unsupported native configurations.
- Keep the native drivers for the subset that is correct.
- Document the CDK-backed path as the supported production path.
- Add a compatibility test for each asset type.

**Files:** `internal/domain/assets/`, `internal/compiler/validator/`,
`internal/pusher/drivers/aws/`, docs.

### 2.3 Kubernetes coverage — Guardian item 8

**Approach**

- Add typed renderers for Ingress, Job, StatefulSet, and DaemonSet (Secret
  already exists).
- Make Service selectors unique per intent/asset (`guardian.partition`,
  `guardian.intent`, `guardian.asset`).
- Prune removed child resources, or document explicit retention.
- Give `K8sResource` ownership labels and real destroy semantics.

**Files:** `internal/pusher/drivers/kubernetes/`.

**Tests:** renderer snapshots, selector uniqueness, prune/retain, destroy.

### 2.4 Repo-level deletion/GC — Guardian item 9

**Approach**

- Record the set of partitions owned by each repo in the ownership manifest.
- When a partition disappears from a repo, mark it for deletion or require
  explicit approval; never delete a partition fed by multiple repos.
- Add a dry-run mode and audit events.

**Files:** `internal/repoimport/`, `internal/ui/repo_import_loop.go`,
`cmd/guardianctl/repo_cmd.go`.

### 2.5 Alert delivery and state — Guardian item 10

**Approach**

- Per-channel retry state with idempotency keys.
- CAS writes for `notifications.json`; conflict retry.
- A partial channel failure must not mark the alert delivered.
- Tests for partial failure, replay, and two-replica races.

**Files:** `internal/alerting/`.

### 2.6 History/rollout scale — Guardian item 11

**Approach**

- Write a summary projection at reconcile time and use it for `/api/overview`.
- Apply history filters/limits during the scan.
- Write and use the archive index (or remove it).
- Add a 100-partition benchmark with an agreed latency budget.

**Files:** `internal/ui/data.go`, `internal/historyquery/`,
`internal/orchestrator/dispatcher/`, benchmarks.

### 2.7 Compliance storage — Guardian item 12

**Approach**

- Retry with backoff and surface terminal failures.
- Add SSE/KMS, Object Lock, and bucket policy configuration.
- Make `Close` idempotent and panic-safe under concurrent publish.
- Tests for retry, encryption options, and concurrent close/publish.

**Files:** `internal/compliance/publisher.go`.

---

## Phase 3 — Guardian maintainability (P2)

1. Split the 43-method AWS `BackendAPI` into per-resource interfaces.
2. Serialize the compiled plan into the task (remove the double parse/TOCTOU).
3. Split `internal/ui/data.go`, `builder.ts`/`main.ts`, Docker/Kubernetes
   `drivers.go`, `guardianctl` command files, and `internal/awsscan/scanner.go`.
4. Unify caches, pagination, map-clone helpers, partition-name listers, and
   sanitizers.
5. Generate the UI asset catalog from typed specs; remove the
   `Database`/`SQLDatabase` alias duplication.
6. Extract one CLI bundle load/validate/write service.
7. Implement `dev setup --repos-dir` cloning (inline TODO).

Each slice is mechanical but large; land them one package at a time with tests
unchanged unless behaviour changes.

---

## Phase 4 — Doctor security blockers (P0)

### 4.1 MonoFS mTLS/credentials — Doctor item 1

**Approach**

- Add CA/client-cert/client-key/server-name configuration and secret mounts.
- Use `credentials.NewTLS` for router and node connections; keep an explicit
  development-only insecure mode gated by config and logged loudly.
- Add an auth metadata token to `LogEngineClient` if MonoFS supports it.
- Fail production startup when TLS is required but misconfigured.
- Document certificate rotation.

**Files:** `internal/store/monofs/{grpc_client,logengine_client}.go`,
`internal/config/config.go`, call sites in `cmd/`.

**Tests:** mTLS round-trip for router and node; plaintext rejected in production;
insecure dev mode requires the explicit flag.

### 4.2 Tenant as a real isolation boundary — Doctor item 2

**Approach**

- Bind tenant to the authenticated principal (OIDC claim, service credential,
  or allowlisted gateway header).
- Enforce tenant in every query/storage key, or add an explicit single-tenant
  mode with a documented boundary.
- Add dashboard/rule tenant ownership and a negative test: user A cannot
  read/write tenant B.
- MonoFS records are physically or logically scoped by tenant.

**Files:** `internal/query/service.go`, `internal/store/monofs/logengine_client.go`,
`internal/dashboards/store.go`, `internal/ruler/store.go`, `internal/config/`.

**Tests:** cross-tenant read/write returns 403; tenant changes by header/param
are rejected; single-tenant mode is explicit.

### 4.3 Dashboard access and audit — Doctor item 3

**Approach**

- Tenant/OWNERS/admin authorization for dashboard mutations and tenant reads.
- Audit events with caller, tenant, dashboard, action, version.
- CSRF token or strict origin check for cookie-authenticated mutations.
- CAS for imports; no silent overwrite.
- ACL test matrix: owner, viewer, foreign tenant, anonymous, admin.

**Files:** `internal/query/dashboards_handlers.go`,
`internal/dashboards/store.go`, `internal/auth/`.

### 4.4 Remote-backend allowlist/egress — Doctor item 4

**Approach**

- Add a shared URL policy: allow only configured schemes (https in production),
  hosts, and optional ports.
- Block loopback, link-local, and private ranges unless explicitly allowed for
  development.
- Reject cross-host redirects when bearer tokens are present.
- Apply the policy to static config, Guardian discovery, federation feeds, and
  AWS backend URLs.
- Tests for blocked loopback/link-local/private and allowed production URLs.

**Files:** `internal/proxy/{backend,discovery_guardian}.go`,
`internal/federation/guardian_feed.go`, `internal/store/aws/client.go`,
new `internal/netguard/`.

### 4.5 Structured audit logging and request IDs — Doctor item 5

**Approach**

- Generate/propagate `X-Request-ID` through HTTP, gRPC, and downstream calls.
- Emit structured events with caller, tenant, action, resource, result, version.
- Cover dashboard CRUD/import/export, rules, federation, Guardian proxies,
  break-glass, and exports.
- Ship audit events separately from debug logs.

**Files:** `internal/query/`, `internal/auth/`, `internal/audit/` (new).

### 4.6 Stop leaking internal errors — Doctor item 6

**Approach**

- Add a stable error envelope `{"error":"...","requestId":"..."}`.
- Log full errors server-side; return generic messages/status.
- Preserve client-visible errors: scope required, too broad, parse error,
  access denied.

**Files:** `internal/query/*.go`.

### 4.7 Security headers — Doctor item 14

**Approach:** middleware for HTML/static responses with CSP,
`X-Content-Type-Options`, frame protection, `Referrer-Policy`, and
`Permissions-Policy`. Document the Grafana embedding requirement.

**Files:** `internal/query/ui.go`, `internal/query/service.go`.

---

## Phase 5 — Doctor correctness and scale (P1/P2)

1. Dashboard import conflict modes (`overwrite`, `skip-existing`,
   `fail-on-conflict`) with per-dashboard conflict details.
2. Populate or remove `Catalog.byTrace`; document the fallback cost.
3. Filter the proxy fleet summary with the same visibility as the page.
4. Bound federation discovery/list responses with pagination, caps, and a
   `truncated` flag.
5. Retention/compaction, HMAC key versioning/re-tokenization, secret-manager
   loading, and rotation docs.
6. Deployment manifests for ingest/query/rules/controller/CLI, MonoFS, and
   Guardian, with probes, limits, non-root UIDs, read-only rootfs, and network
   policies.
7. Frontend tests/typecheck/lint/contract checks in CI; `govulncheck` and
   `staticcheck`.
8. Remove structural duplication and dead packages; split oversized files.
9. Fix the remaining nits: WAL frame metadata, metric metadata, trace/metric
   field preservation, body limits, `envDuration`, unused settings, pinned
   actions, `make verify`.

---

## Phase 6 — Demo cleanup and final verification

- Rewrite `demo/TODO.md` as a short verification checklist:
  1. `./demo.sh doctor`
  2. `./demo.sh up`
  3. `./demo.sh seed`
  4. `./demo.sh test --scenario all`
  5. Confirm S1/S2/S3/S4/S7/S8, sign-out, and UI badges.
- Delete completed entries permanently; keep only the clean-run acceptance.
- Record the run timestamp/commit in `demo/README.md`.

---

## Execution log

| Date | Item | Change | Tests |
|---|---|---|---|
| 2026-11-01 | Demo items 1,4,5,6 | Marked complete and removed from `demo/TODO.md` | n/a |
| 2026-11-01 | Plan | Added this document | n/a |
| 2026-11-01 | Guardian 1 (partial) | Reconciler sharding wired; watcher reconciles respect ownership | `go test ./internal/orchestrator/reconciler` |
| 2026-11-01 | Guardian 7 (partial) | Strict native-AWS mode rejects experimental asset drivers and points to CDK | `go test ./internal/compiler/validator` |
| 2026-11-01 | Guardian 8 (partial) | Documented Secret renderer and generic `K8sResource` interim path | n/a |
| 2026-11-01 | Guardian 9 (partial) | Removed partitions are reported as `Orphaned` instead of silently ignored | `go test ./internal/repoimport` |
| 2026-11-01 | Guardian 2 (partial) | UI auth mode, CSRF/Origin checks, CSP/security headers, HSTS | `go test ./internal/ui` |
| 2026-11-01 | Guardian 4 (partial) | AWS read API TLS/mTLS, scopes, rotation, rate/body limits, diff off by default | `go test ./internal/awsread` |
| 2026-11-01 | Guardian 6 (partial) | Task archive retention and SHA-256 hash chain | `go test ./internal/orchestrator/dispatcher` |
| 2026-11-01 | Guardian 10 (partial) | Per-channel retry, idempotency, CAS notification state | `go test ./internal/alerting` |
| 2026-11-01 | Guardian 12 | Compliance retry, SSE/KMS, Object Lock, idempotent close | `go test ./internal/compliance` |
| 2026-11-01 | Guardian 13 (partial) | Non-root images, Make targets, CI vet/build/vuln scan, no go.sum deletion | `go vet`; image review |
| 2026-11-01 | Guardian 14 (partial) | Storeless guard, bounded probe history, shared transports | `go test ./internal/pusher/probes` |
| 2026-11-01 | Doctor 1 (partial) | MonoFS TLS/mTLS configuration and fail-closed path | `go test ./internal/store/monofs` |
| 2026-11-01 | Doctor 2 (partial) | Tenant allowlist/single-tenant guard | `go test ./internal/auth` |
| 2026-11-01 | Doctor 3 (partial) | CSRF/origin checks and structured audit events | `go test ./internal/query` |
| 2026-11-01 | Doctor 4 | URL policy blocks SSRF targets for static/discovered backends | `go test ./internal/netguard ./internal/proxy` |
| 2026-11-01 | Doctor 7 | Dashboard import conflict modes and CAS | `go test ./internal/query` |
| 2026-11-01 | Doctor 8 | Removed dead trace index; documented bounded fallback | `go test ./internal/federation` |
| 2026-11-01 | Doctor 9 | Fleet summary filtered by identity visibility | `go test ./internal/proxy` |
| 2026-11-01 | Doctor 12 | Reference Kubernetes manifests with probes/limits/network policies | YAML parse |
| 2026-11-01 | Doctor 13 | Vitest suite and CI test/typecheck/vet/vuln scan | `npm test`; `npm run build` |
| 2026-11-01 | Doctor 14 | CSP/security headers on UI and API responses | `go test ./internal/query` |
| 2026-11-01 | Doctor 15/17 (partial) | Removed dead packages/page, added body limit and `make verify` | `go test ./...` |
| 2026-11-01 | Demo | Replaced stale checklist with one clean-run acceptance item | n/a |

Update this table as each item lands.
