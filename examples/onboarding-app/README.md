# Example onboarding application

This folder is a complete example of the repository layout expected by the
public Strata bootstrap. The application lives in its own repository and owns
one dedicated Guardian partition.

```text
onboarding-app/
├── .guardian/config.yaml                     # repo registration
├── app/                                      # application source + Dockerfile
│   ├── Dockerfile
│   ├── go.mod
│   └── main.go
└── guardian/partitions/onboarding-app/       # dedicated partition
    ├── config.yaml
    └── intents/app.yaml
```

## Build the image

```bash
docker build -t ghcr.io/your-org/onboarding-app:dev ./app
docker push ghcr.io/your-org/onboarding-app:dev
```

Then update `guardian/partitions/onboarding-app/intents/app.yaml` with the
image reference.

## Local kind quickstart

From a checked-out Strata workspace:

```bash
# Build and load the example image into the kind cluster.
docker build -t strata/onboarding-app:dev examples/onboarding-app/app
kind load docker-image strata/onboarding-app:dev --name strata-dev

# Register the repository and import its partition.
guardianctl --guardian-url http://127.0.0.1:18090 repo add \
  --name onboarding-app \
  --pusher k8s-main \
  --partition onboarding-app \
  --source "$PWD/examples/onboarding-app"
guardianctl --guardian-url http://127.0.0.1:18090 repo import \
  --name onboarding-app \
  --source "$PWD/examples/onboarding-app"
```

The `repo add` call only registers the source; `repo import` reads
`guardian/partitions/**` and reconciles the partition.

For the full step-by-step guide, see
[`docs/onboarding-application.md`](../../docs/onboarding-application.md).
