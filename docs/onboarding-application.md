# Onboard an application from its own repository

Strata expects each application to own a **dedicated partition** inside its
repository. Guardian reads that partition, compiles it, and reconciles it to the
target pusher (Kubernetes or AWS).

This keeps the application repository self-contained: application code, CI, and
the deployment contract live together.

## Repository layout

```text
my-app/
├── .guardian/config.yaml                     # repo registration
├── app/                                      # application source
│   ├── Dockerfile
│   └── ...
├── .github/workflows/strata-deploy.yml       # optional CI
└── guardian/partitions/my-app/               # dedicated partition
    ├── config.yaml
    ├── intents/
    │   └── app.yaml
    └── payloads/                             # optional config/scripts
```

The partition name must match the directory name and the `partition` field in
`.guardian/config.yaml`.

## 1. Create `.guardian/config.yaml`

```yaml
apiVersion: guardian/v1alpha1
kind: RepoConfig
pusher:
  name: k8s-main
  description: Kubernetes cluster used by this application
repo:
  name: my-app
  partition: my-app
  source: .
  description: My application managed by Guardian
```

For AWS, set the pusher to the AWS pusher registered in Guardian, for example
`aws-123456789012`, and add the target account/region to the intent.

## 2. Create the partition

`guardian/partitions/my-app/config.yaml`:

```yaml
apiVersion: guardian/v1alpha1
kind: Partition
metadata:
  name: my-app
  labels:
    role: application
spec:
  defaults:
    probes:
      enabled: true
      interval: 30s
      timeout: 3s
      retries: 2
      httpPaths: ["/healthz"]
  deletionPolicy: destroy
  reconciliation:
    mode: auto
    interval: 1m
```

`guardian/partitions/my-app/intents/app.yaml`:

```yaml
apiVersion: guardian/v1alpha1
kind: Intent
metadata:
  name: app
spec:
  intentType: standard
  targetPusher: k8s-main
  target:
    cluster: k8s-main
    namespace: my-app
  assets:
    - type: Compute
      name: app
      properties:
        image: ghcr.io/your-org/my-app:sha-<commit>
        imagePullPolicy: IfNotPresent
        env:
          PORT: "8080"
        ports:
          - containerPort: 8080
            name: http
            protocol: TCP
            servicePort: 8080
        resources:
          limits: { cpu: 250m, memory: 256Mi }
          requests: { cpu: 50m, memory: 64Mi }
    - type: Probe
      name: app-health
      dependsOn: [app]
      properties:
        target: app
        type: http
        path: /healthz
        port: 8080
        interval: 30s
        timeout: 3s
        retries: 2
```

No credentials belong in the repository. If the application needs a secret,
add a `Secret` asset with `secretRef` (for example
`monofs-secret://my-app/db-password`) and create the referenced secret through
Guardian or your secret manager.

## 3. Build and publish the image

Any registry works. Example:

```bash
docker build -t ghcr.io/your-org/my-app:"sha-$(git rev-parse --short HEAD)" ./app
docker push ghcr.io/your-org/my-app:"sha-$(git rev-parse --short HEAD)"
```

Commit the same image reference in `intents/app.yaml`, or render it in CI before
pushing the partition.

## 4. Onboard the repository

### Local kind

```bash
cd ../strata
./scripts/onboard-app.sh --repo ../my-app
```

For the sample app, this is already done by `dev-kind-up.sh`.

### Existing Kubernetes cluster

```bash
export GUARDIAN_URL=http://guardian.example.com
./scripts/onboard-app.sh --repo ../my-app --pusher k8s-main
```

The script reads `.guardian/config.yaml` and pushes
`guardian/partitions/<name>` directly. Pass `--register` to also record the
repository in Guardian (`repo add` + `repo import`) for repo-driven syncs; the
pusher must already be registered for that mode.

For an AWS pusher, set the pusher name in `.guardian/config.yaml` and the
account/region in the intent. `--pusher` is only needed with `--register`.

### Manifest-only path

If you do not want to register a repository, push the partition directly:

```bash
guardianctl --guardian-url "$GUARDIAN_URL" partition push \
  --dir ../my-app/guardian/partitions/my-app
```

## 5. CI example

```yaml
name: Deploy with Strata

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - run: |
          IMAGE="ghcr.io/${{ github.repository }}:sha-${GITHUB_SHA::8}"
          docker build -t "$IMAGE" ./app
          docker push "$IMAGE"
          sed -i "s|image: .*|image: $IMAGE|" guardian/partitions/my-app/intents/app.yaml
      - name: Push partition
        env:
          GUARDIAN_URL: ${{ secrets.GUARDIAN_URL }}
          GUARDIAN_TOKEN: ${{ secrets.GUARDIAN_TOKEN }}
        run: |
          go install github.com/radryc/guardian/cmd/guardianctl@latest
          guardianctl --guardian-url "$GUARDIAN_URL" partition push \
            --dir guardian/partitions/my-app
```

Use a dedicated Guardian service token or OIDC workload identity in CI. Do not
store a human SSO session.

## 6. Verify

```bash
guardianctl --guardian-url "$GUARDIAN_URL" partition status --partition my-app
guardianctl --guardian-url "$GUARDIAN_URL" intent status --partition my-app --intent app
kubectl -n my-app get deploy,svc,pods
```

Guardian exposes drift and apply failures in the UI and through `intent status`.

## What the bootstrap prepared for you

`bootstrap/partitions/onboarding-app/` is a ready-to-render partition. The only
placeholder is `__APP_IMAGE__`, which the local bootstrap replaces with the
image it just built. It contains no private keys or account IDs, so it is safe
to commit and easy for `dev-kind-up.sh` to modify.

The sample application under `examples/onboarding-app/` is the same layout as a
real application repository and can be copied as a starting point.
