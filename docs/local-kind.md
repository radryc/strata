# Local developer stack on kind

This is the fastest path from a fresh clone to a running Strata control plane
with Guardian, MonoFS, Doctor, and a sample application.

## Prerequisites

- Docker (running, with BuildKit)
- kind
- kubectl
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

Guardian, Doctor, and MonoFS all authenticate through Authentik. Doctor and
MonoFS redirect anonymous browsers to the login page; use the **Log in** button
on Guardian. The development Authentik admin is `akadmin` / `password`
(`admin@example.com`, granted admin on all partitions).

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

## Troubleshooting

- **Pod CrashLoopBackOff:** `kubectl -n strata describe pod <pod>` and
  `kubectl -n strata logs <pod> --previous`.
- **Guardian has no task:** confirm the `k8s-main` pusher pod is running and
  that `guardianctl --guardian-url http://127.0.0.1:18090 pusher list` shows it.
- **App image pull error:** the kind stack uses `imagePullPolicy: IfNotPresent`
  and loads the sample image with `kind load docker-image`. For your own image,
  either load it into kind or push it to a registry the cluster can reach.
- **Port already in use:** stop the conflicting process or edit the
  port-forward ports in `scripts/lib/bootstrap-common.sh`.
- **Authentik login fails:** check `kubectl -n authentik get pods` and
  `kubectl -n authentik logs deploy/authentik-server`.

## DuckDB query sidecar

The MonoFS server pod includes a `monofs-logquery` sidecar that reads the same
node-local logengine volume and serves the DuckDB-backed telemetry query RPCs.
`monofs-server` is started with `--logquery-sidecar=127.0.0.1:9101`; the
sidecar is built from `monofs/Dockerfile.logquery` and loaded into kind with
the other MonoFS images. This is what powers Doctor's read-only SQL console.
