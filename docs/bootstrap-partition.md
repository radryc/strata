# Prepared bootstrap partition

The public bootstrap ships a ready-to-render partition at:

```text
bootstrap/partitions/onboarding-app/
├── config.yaml
└── intents/app.yaml
```

It is deliberately free of private keys, account IDs, and registry credentials.
The only dynamic values are placeholders:

| Placeholder | Replaced by | Value in the local quickstart |
|---|---|---|
| `__APP_IMAGE__` | `dev-kind-up.sh` / `render_template` | `strata/onboarding-app:dev` |
| `__IMAGE_PREFIX__` | image prefix renderer | `strata` |
| `__IMAGE_TAG__` | image tag renderer | `dev` |
| `__NAMESPACE__` | namespace renderer | `strata` |

`dev-kind-up.sh` renders the partition into `.strata/partitions/` and pushes it
with `guardianctl partition push`. The checked-in files are never modified.

## Customize it

Copy the directory into your application repository:

```bash
mkdir -p ../my-app/guardian/partitions
cp -R bootstrap/partitions/onboarding-app ../my-app/guardian/partitions/my-app
```

Then:

1. rename the partition in `config.yaml`;
2. set the image reference in `intents/app.yaml`;
3. adjust the namespace and resources;
4. add the matching `.guardian/config.yaml` (see the sample application);
5. push it with `./scripts/onboard-app.sh --repo ../my-app` (or register the
   repository with `guardianctl repo add` + `repo import`).

## Secrets

Do not put private keys in the partition. Use a `Secret` asset with a
`secretRef`:

```yaml
- type: Secret
  name: db-password
  properties:
    secretRef: monofs-secret://my-app/db-password
```

The bootstrap generates only local development tokens for the platform itself
and stores them in `.strata/dev.env`, which is gitignored. Production secrets
belong in your secret manager or Kubernetes Secret, not in this repository.
