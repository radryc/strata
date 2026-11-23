# Bootstrap assets

This directory is the public, self-contained deployment layer for Strata. It
does not require the private `demo-divisions` or `stratatools` repositories.

```text
bootstrap/
├── kind/cluster.yaml                  # kind cluster used by dev-kind-up.sh
├── auth/                              # development Authentik SSO reference
│   ├── README.md
│   └── authentik.yaml
├── k8s/                               # reference control-plane manifests
│   ├── 00-namespace.yaml
│   ├── 10-monofs-fetcher.yaml
│   ├── 10-monofs.yaml
│   ├── 20-guardian.yaml
│   └── 30-doctor.yaml
└── partitions/
    ├── aws-app/                       # empty placeholder (no config or intents)
    └── onboarding-app/                # prepared application partition
        ├── config.yaml
        └── intents/app.yaml
```

`bootstrap/partitions/aws-app/` is currently an empty placeholder: its
`intents/` directory contains no manifests. The AWS application example lives in
[`examples/aws-app/`](../examples/aws-app/README.md).

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

The prepared partition only contains the `__APP_IMAGE__` placeholder. The
platform manifests additionally use `__IMAGE_PREFIX__`, `__IMAGE_TAG__`, and
`__NAMESPACE__`. The bootstrap renders all of them into `.strata/`; the
checked-in files are never modified. No private keys, account IDs, or registry
credentials are stored here.

See:

- [auth/README.md](auth/README.md)
- [../docs/local-kind.md](../docs/local-kind.md)
- [../docs/access-and-login.md](../docs/access-and-login.md)
- [../docs/kubernetes.md](../docs/kubernetes.md)
- [../docs/aws.md](../docs/aws.md)
- [../docs/onboarding-application.md](../docs/onboarding-application.md)
- [../docs/bootstrap-partition.md](../docs/bootstrap-partition.md)
