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

Build and push the image your deployment will run, then point the intent at it:

```bash
docker build -t ghcr.io/your-org/onboarding-app:dev ./app
docker push ghcr.io/your-org/onboarding-app:dev
```

Edit `guardian/partitions/onboarding-app/intents/app.yaml` and replace
`ghcr.io/your-org/onboarding-app:latest` with the tag you pushed. The checked-in
intent keeps a placeholder image on purpose. The prepared partition under
`bootstrap/partitions/onboarding-app` uses the `__APP_IMAGE__` placeholder
instead; `dev-kind-up.sh` renders it to your local image automatically.

## Local kind quickstart

From a checked-out Strata workspace:

```bash
# Build and load the example image into the kind cluster.
docker build -t strata/onboarding-app:dev examples/onboarding-app/app
kind load docker-image strata/onboarding-app:dev --name strata-dev

# The checked-in intent targets ghcr.io/your-org/onboarding-app:latest, and
# onboard-app.sh pushes the files as-is (it does not render placeholders).
# Edit examples/onboarding-app/guardian/partitions/onboarding-app/intents/app.yaml
# and set image: strata/onboarding-app:dev before pushing.
./scripts/onboard-app.sh --repo "$PWD/examples/onboarding-app"
```

If you already ran `./scripts/bootstrap.sh up`, the prepared
`bootstrap/partitions/onboarding-app` partition is deployed with the local
image, so this step is only needed when you want Guardian to manage this example
repository's own partition.

Pass `--register` to also record the repository in Guardian for repo-driven
syncs (the pusher must already be registered).

For the full step-by-step guide, see
[`docs/onboarding-application.md`](../../docs/onboarding-application.md).
