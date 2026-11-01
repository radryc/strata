# Deploy Strata to an existing Kubernetes cluster

The same manifests used by the local kind quickstart work on a normal cluster.
Images must be available to the cluster (pushed to a registry, or loaded into
the nodes).

## 1. Clone and configure

```bash
git clone https://github.com/radryc/strata.git
cd strata
./scripts/clone.sh
```

Pick a registry prefix you can push to:

```bash
export STRATA_IMAGE_PREFIX=ghcr.io/your-org/strata
export STRATA_IMAGE_TAG=2026-11-01
export STRATA_APP_IMAGE=ghcr.io/your-org/onboarding-app:2026-11-01
docker login ghcr.io
```

## 2. Build and push

```bash
./scripts/bootstrap.sh k8s --build --push --no-port-forward
```

Or build locally and push with your own pipeline:

```bash
docker build --target router -t "$STRATA_IMAGE_PREFIX/monofs-router:$STRATA_IMAGE_TAG" ../monofs
docker build --target server -t "$STRATA_IMAGE_PREFIX/monofs-server:$STRATA_IMAGE_TAG" ../monofs
docker build --target fetcher -t "$STRATA_IMAGE_PREFIX/monofs-fetcher:$STRATA_IMAGE_TAG" ../monofs
DOCKER_BUILDKIT=1 docker build \
  --build-context monofs=../monofs --build-context kvs=../kvs \
  -t "$STRATA_IMAGE_PREFIX/guardiand:$STRATA_IMAGE_TAG" ../guardian
DOCKER_BUILDKIT=1 docker build \
  --build-context monofs=../monofs --build-context kvs=../kvs \
  -f ../guardian/Dockerfile.pusher-k8s \
  -t "$STRATA_IMAGE_PREFIX/guardian-pusher-k8s:$STRATA_IMAGE_TAG" ../guardian
DOCKER_BUILDKIT=1 docker build \
  --build-context monofs=../monofs --build-arg DOCTOR_SERVICE=doctor-ingest \
  -t "$STRATA_IMAGE_PREFIX/doctor-ingest:$STRATA_IMAGE_TAG" ../doctor
DOCKER_BUILDKIT=1 docker build \
  --build-context monofs=../monofs --build-arg DOCTOR_SERVICE=doctor-query \
  -t "$STRATA_IMAGE_PREFIX/doctor-query:$STRATA_IMAGE_TAG" ../doctor
```

## 3. Create secrets

`k8s-up.sh` generates fresh local tokens automatically. For production, create
the secret from your secret manager instead:

```bash
kubectl create namespace strata
kubectl -n strata create secret generic strata-secrets \
  --from-literal="MONOFS_TOKEN=$(openssl rand -hex 32)" \
  --from-literal="MONOFS_ENCRYPTION_KEY=$(openssl rand -hex 32)" \
  --from-literal="DOCTOR_INGEST_AUTH_TOKEN=$(openssl rand -hex 32)" \
  --from-literal="DOCTOR_PRIVACY_HMAC_KEY=$(openssl rand -hex 32)"
```

Never commit these values. The MonoFS encryption key is required to read
existing data; back it up.

## 4. Apply

```bash
./scripts/k8s-up.sh --no-port-forward --skip-app
```

The manifests live in `bootstrap/k8s/`:

| File | Contents |
|---|---|
| `00-namespace.yaml` | `strata` namespace |
| `10-monofs-fetcher.yaml` | MonoFS fetcher (blob/cache service) |
| `10-monofs.yaml` | MonoFS server PVC + router/server Deployments |
| `20-guardian.yaml` | Guardian daemon, Kubernetes pusher, RBAC |
| `30-doctor.yaml` | OTLP ingest + Doctor query |

Expose Guardian/Doctor through your ingress or `kubectl port-forward`:

```bash
kubectl -n strata port-forward svc/guardiand 18090:8090
kubectl -n strata port-forward svc/doctor-query 18080:18080
```

## 5. Onboard an application

The sample partition is `bootstrap/partitions/onboarding-app`. For a real
repository, follow [onboarding-application.md](onboarding-application.md).

## Production notes

The reference manifests use a single MonoFS server with a 5 Gi PVC and a
single Guardian replica. Before production:

- use a managed or multi-node storage class and back it up;
- set `GUARDIAN_REQUIRE_UI_AUTH=true` and configure OIDC;
- restrict the pusher ClusterRole to the namespaces/resources you actually use;
- run at least two Guardian replicas and configure sharding or leader election;
- terminate TLS at the ingress and enable `GUARDIAN_ENABLE_HSTS=true`;
- set `DOCTOR_MONOFS_TLS_REQUIRE=true` and mount MonoFS client certificates;
- replace the generated secrets with your secret manager.
