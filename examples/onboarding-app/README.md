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

# Push the dedicated partition.
./scripts/onboard-app.sh --repo "$PWD/examples/onboarding-app"
```

Pass `--register` to also record the repository in Guardian for repo-driven
syncs (the pusher must already be registered).

For the full step-by-step guide, see
[`docs/onboarding-application.md`](../../docs/onboarding-application.md).
