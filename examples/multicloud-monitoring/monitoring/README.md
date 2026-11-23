# Monitoring

This example reuses the canonical platform monitoring bundle instead of
duplicating generated dashboards:

```text
../../../../stratatools/partitions/monitoring
```

The bundle lives in the separate `stratatools` repository, which
`scripts/clone.sh` does not clone. Check it out as a sibling of `strata` before
running the commands below; the relative paths assume that layout.

It deploys Grafana, the Grafana datasources backed by Doctor (metrics, logs,
traces), and the cross-provider dashboards for `diva-shared` / `divb-shared`
plus the platform health boards.

## Apply

```bash
cd ../../../../guardian
./bin/guardianctl release run --partition monitoring --build --bump
```

Or, if the images are already built and stamped:

```bash
./bin/guardianctl partition push \
  --dir ../../../../stratatools/partitions/monitoring
./bin/guardianctl partition reconcile --partition monitoring
```

## Prerequisites

The platform monitoring bundle expects the platform partitions to exist:

- `k8s-top` for Kubernetes resource panels
- `opentelemetry` and/or `prometheus` for the metrics source
- `monofs`, `doctor`, and `guardian` for their health boards
- the `monofs-external` / `lb-edge` service for the Grafana edge port

If you deploy this example into a bare cluster, bring up those platform
partitions first (normal Strata bootstrap), then apply the multicloud example
and monitoring.

## Access

Grafana is served through the shared lb-edge Service on port `3000`
(`grafana-edge`). The example ACL grants `admin@example.com` the `monitoring`
partition so the platform admin can open the boards; `usera` and `userb` see
only their division's logs and traces through Doctor.
