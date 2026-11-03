# Bootstrap assets

This directory is the public, self-contained deployment layer for Strata. It
does not require the private `demo-divisions` or `stratatools` repositories.

```text
bootstrap/
├── kind/cluster.yaml                  # kind cluster used by dev-kind-up.sh
├── auth/authentik.yaml                # development Authentik SSO reference
├── k8s/                               # reference control-plane manifests
│   ├── 00-namespace.yaml
│   ├── 10-monofs-fetcher.yaml
│   ├── 10-monofs.yaml
│   ├── 20-guardian.yaml
│   └── 30-doctor.yaml
└── partitions/onboarding-app/         # prepared application partition
    ├── config.yaml
    └── intents/app.yaml
```

The platform repositories also own their Guardian partitions:

```text
monofs/guardian/partitions/monofs/
guardian/guardian/partitions/guardian/
doctor/guardian/partitions/doctor/
```

`dev-kind-up.sh` ingests those repositories into MonoFS, registers them with
Guardian, and imports the partitions. The partitions observe the
bootstrap-started workloads and add probes; they do not create duplicate
deployments. The manifests use the default `strata` namespace.

The only placeholders in the prepared partition are `__APP_IMAGE__`,
`__IMAGE_PREFIX__`, `__IMAGE_TAG__`, and `__NAMESPACE__`. The bootstrap renders
them into `.strata/`; the checked-in files are never modified. No private keys,
account IDs, or registry credentials are stored here.

See:

- [../docs/local-kind.md](../docs/local-kind.md)
- [../docs/access-and-login.md](../docs/access-and-login.md)
- [../docs/kubernetes.md](../docs/kubernetes.md)
- [../docs/aws.md](../docs/aws.md)
- [../docs/onboarding-application.md](../docs/onboarding-application.md)
- [../docs/bootstrap-partition.md](../docs/bootstrap-partition.md)
