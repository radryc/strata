# Local developer stack on kind

This is the fastest path from a fresh clone to a running Strata control plane
with Guardian, MonoFS, Doctor, and a sample application.

## Prerequisites

- Docker (running, with BuildKit)
- kind
- kubectl
- curl
- Go 1.26+
- OpenSSL
- Node 22 only if you build the Guardian UI from source
- Network access to GitHub for the first MonoFS ingestion of the platform
  repositories

## One command

From the `strata` repository:

```bash
./scripts/bootstrap.sh up
```

`bootstrap.sh up` delegates to `dev-kind-up.sh`. Both are equivalent.

The script:

1. creates a `strata-dev` kind cluster;
2. builds MonoFS (router, server, fetcher), Guardian, Doctor, and the example
   application images from the local checkouts;
3. loads the images into kind;
4. generates local-only MonoFS and Doctor secrets in `.strata/dev.env`;
5. starts the control plane in the `strata` namespace;
6. deploys Authentik and enables OIDC login;
7. ingests the public `monofs`, `guardian`, and `doctor` repositories into
   MonoFS and registers them with Guardian;
8. imports each repository's `guardian/partitions/<name>` bundle, which adds
   observed platform partitions and probes for MonoFS, Guardian, and Doctor;
9. pushes the prepared `bootstrap/partitions/onboarding-app` partition;
10. starts port-forwards.

When it finishes:

| URL | What |
|---|---|
| <http://127.0.0.1:28090> | Guardian UI (Authentik login) |
| <http://127.0.0.1:28080> | Doctor UI (Authentik login) |
| <http://127.0.0.1:28081> | MonoFS UI (Authentik login) |
| <http://127.0.0.1:29020> | Authentik |
| <http://127.0.0.1:18088> | Sample application |

Guardian, Doctor, and MonoFS all authenticate through Authentik and redirect
anonymous browsers to its login page. The development Authentik admin is
`akadmin` / `password` (`admin@example.com`), which the repo-managed access
policy grants admin across the platform partitions once it is published.

Create another user and set their password:

```bash
./scripts/create-authentik-user.sh \
  --username alice --email alice@example.com \
  --password 'choose-a-password' \
  --grant maintainer --partition onboarding-app
```

The direct endpoints `18090` (Guardian API), `19090` (MonoFS gRPC), and `9000`
(MonoFS node) are for `guardianctl` and local debugging. Do not expose them
outside your machine.

## Platform partitions

The public platform repositories own their Guardian partitions:

```text
monofs/guardian/partitions/monofs/
guardian/guardian/partitions/guardian/
doctor/guardian/partitions/doctor/
```

Each partition observes the workloads that the bootstrap already started
(`observeExisting: true`) and adds health probes. This keeps the
chicken-and-egg bootstrap simple while making the platform visible in Guardian.

The bootstrap ingests the GitHub remotes into MonoFS, registers the repositories
with Guardian, and imports the partitions. The partition manifests target the
default `strata` namespace and are safe to re-import; they do not duplicate the
bootstrap deployments.

If you change the platform images or add workloads later, update the partition
manifest in that repository and let Guardian's repo-import loop pick it up.

## Onboard a real application repository

The sample application already demonstrates the layout. To onboard another
repository, see [onboarding-application.md](onboarding-application.md).

```bash
./scripts/onboard-app.sh --repo ../my-app
```

## Rebuild without recreating the cluster

```bash
./scripts/dev-kind-up.sh --skip-build
./scripts/dev-kind-up.sh --reset     # delete and recreate the kind cluster
```

## Teardown

```bash
./scripts/dev-kind-down.sh              # delete the kind cluster
./scripts/dev-kind-down.sh --keep-cluster
./scripts/dev-kind-down.sh --purge      # also remove generated secrets
```

## What is generated locally

`.strata/` contains:

- `dev.env` — generated tokens; never commit this;
- `rendered-k8s/` — manifests rendered with your namespace and image prefix;
- `partitions/` — the prepared partition rendered with your image reference;
- `pids/` and `logs/` — port-forward state.

The repository's `.gitignore` excludes `.strata/`.

## Access the deployed application

The bootstrap deploys the sample application through Guardian, not as a static
manifest. It lands in the `onboarding-app` namespace with generated resource
names (`k8s-compute-...`, `k8s-svc-...`).

### Browser

The bootstrap starts a port-forward for the deployed service:

```
http://127.0.0.1:18088
```

There is no ingress. If the app pod is replaced the port-forward dies; restart
it against the current service:

```bash
SVC="$(kubectl -n onboarding-app get svc -l guardian.asset=app -o jsonpath='{.items[0].metadata.name}')"
kubectl -n onboarding-app port-forward "svc/$SVC" 18088:8080
```

### Guardian UI

Open <http://127.0.0.1:28090> and sign in through Authentik
(`akadmin` / `password`). The `onboarding-app` partition lists the `app` intent
and its Compute/Probe assets, drift state, and health.

### Guardian CLI

`guardianctl` is built into `.strata/bin/guardianctl` during bootstrap. For the
local stack, use the MonoFS router and token from `.strata/dev.env`:

```bash
cd strata
set -a; . .strata/dev.env; set +a
export GUARDIAN_MONOFS_ALLOW_PLAINTEXT=true

.strata/bin/guardianctl --monofs-router 127.0.0.1:19090 \
  --monofs-token "$MONOFS_TOKEN" partition list

.strata/bin/guardianctl --monofs-router 127.0.0.1:19090 \
  --monofs-token "$MONOFS_TOKEN" partition status --partition onboarding-app

.strata/bin/guardianctl --monofs-router 127.0.0.1:19090 \
  --monofs-token "$MONOFS_TOKEN" intent status \
  --partition onboarding-app --intent app
```

To use the HTTP API with an SSO session instead:

```bash
.strata/bin/guardianctl auth login \
  --issuer http://127.0.0.1:29020/application/o/monofs/ \
  --client-id monofs --client-secret monofs-oidc-secret
.strata/bin/guardianctl --guardian-url http://127.0.0.1:18090 partition list
```

### Kubernetes

```bash
kubectl -n onboarding-app get deploy,svc,pod
kubectl -n onboarding-app logs deploy/<deployment-name> -f
kubectl -n onboarding-app exec deploy/<deployment-name> -- wget -qO- localhost:8080/healthz
```

## Access Doctor

Sign in through Authentik at **<http://127.0.0.1:28080>**. The UI shows
traces, logs, metrics, the SQL console, and Guardian health.

The **OTLP ingest listener is cluster-internal** (`doctor-ingest:4317` gRPC,
`:4318` HTTP). Forward it to the host when you need to send telemetry from
outside the cluster:

```bash
kubectl -n strata port-forward svc/doctor-ingest 4317:4317 4318:4318
```

Ingest requires the token from `.strata/dev.env`; `/healthz` is anonymous:

```bash
curl -s http://127.0.0.1:4318/healthz
# {"status":"ok"}

set -a; . .strata/dev.env; set +a
curl -sS -X POST http://127.0.0.1:4318/v1/traces \
  -H "Authorization: Bearer $DOCTOR_INGEST_AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @span.json
# 202 {}
```

That shared token is scoped to the `default` tenant. Send
`X-Doctor-Tenant: <name>` to select another tenant when your credential allows
it; gRPC uses the `x-doctor-tenant` metadata key and the same
`authorization: Bearer ...` metadata.

`doctor-query` also serves Grafana-compatible read APIs on the same port:

| API | Paths |
|---|---|
| Prometheus | `/api/v1/query`, `/api/v1/query_range`, `/api/v1/labels`, `/api/v1/series` |
| Loki | `/loki/api/v1/query`, `/loki/api/v1/query_range`, `/loki/api/v1/labels` |
| Tempo | `/api/search`, `/api/traces/<trace-id>` |

With OIDC enabled these return `401` anonymously. Use the UI, or send a bearer
token issued by Authentik. `/healthz`, `/ready`, and `/metrics` stay open.

## Access MonoFS

Sign in through Authentik at **<http://127.0.0.1:28081>** to browse the
ingested repositories and files, workspaces, and the search/tree UI.

The gRPC router is exposed as `127.0.0.1:19090` and is what control-plane
clients use. It requires the MonoFS bearer token:

```bash
cd strata
set -a; . .strata/dev.env; set +a
export GUARDIAN_MONOFS_ALLOW_PLAINTEXT=true

# Repositories registered in MonoFS/Guardian
.strata/bin/guardianctl --monofs-router 127.0.0.1:19090 \
  --monofs-token "$MONOFS_TOKEN" repo list

# Ingest another Git repository
.strata/bin/monofs-admin ingest \
  --router 127.0.0.1:19090 \
  --source https://github.com/example/repo \
  --ingestion-type git --fetch-type blob --replicate-data=true \
  --token "$MONOFS_TOKEN"
```

Note: `monofs-admin status` and `monofs-admin repos` do not attach a bearer
token yet, so they return `401` on this auth-enabled stack. Use the UI or the
token-aware commands above.

The node API is also forwarded on `127.0.0.1:9000` for debugging. In-cluster
clients should use `monofs-router.strata.svc.cluster.local:9090` (gRPC) or
`monofs-server.strata.svc.cluster.local:9000` (node).

Filesystem access uses `monofs-client` from the `monofs` checkout. It needs
FUSE 3 and node addresses the host can reach; this kind bootstrap advertises
`monofs-server:9000` (cluster DNS), so a host mount only works after changing
the router's `--external-addrs` to a forwarded address (for example
`node-a=127.0.0.1:9000`) and using `--use-external-addrs`. Without that, use the
UI or run the client inside the cluster.

## Troubleshooting

- **Pod CrashLoopBackOff:** `kubectl -n strata describe pod <pod>` and
  `kubectl -n strata logs <pod> --previous`.
- **Guardian has no task:** confirm the `k8s-main` pusher pod is running and
  that `guardianctl --guardian-url http://127.0.0.1:18090 pusher list` shows it.
- **App image pull error:** the kind stack uses `imagePullPolicy: IfNotPresent`
  and loads the sample image with `kind load docker-image`. For your own image,
  either load it into kind or push it to a registry the cluster can reach.
- **Port already in use:** stop the conflicting process or edit the
  port-forward ports in `scripts/dev-kind-up.sh` (the sample app port lives in
  `scripts/lib/bootstrap-common.sh`).
- **Authentik login fails:** check `kubectl -n authentik get pods` and
  `kubectl -n authentik logs deploy/authentik-server`.

## DuckDB query sidecar

The MonoFS server pod includes a `monofs-logquery` sidecar that reads the same
node-local logengine volume and serves the DuckDB-backed telemetry query RPCs.
`monofs-server` is started with `--logquery-sidecar=127.0.0.1:9101`; the
sidecar is built from `monofs/Dockerfile.logquery` and loaded into kind with
the other MonoFS images. This is what powers Doctor's read-only SQL console.
