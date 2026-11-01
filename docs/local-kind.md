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

## One command

From the `strata` repository:

```bash
./scripts/clone.sh          # only needed once; clones the sibling public repos
./scripts/dev-kind-up.sh
```

The script:

1. creates a `strata-dev` kind cluster;
2. builds MonoFS, Guardian, and Doctor images from the local checkouts;
3. loads the images into kind;
4. generates local-only MonoFS and Doctor tokens in `.strata/dev.env`;
5. starts the control plane in the `strata` namespace;
6. pushes the prepared `bootstrap/partitions/onboarding-app` partition;
7. starts port-forwards.

When it finishes:

| URL | What |
|---|---|
| <http://127.0.0.1:18090> | Guardian UI |
| <http://127.0.0.1:18080> | Doctor UI |
| <http://127.0.0.1:18081> | MonoFS UI |
| <http://127.0.0.1:18088> | Sample application |

Useful commands:

```bash
kubectl -n strata get pods
kubectl -n strata logs deploy/guardiand -f
kubectl -n onboarding-app get deploy,svc,pods
```

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
