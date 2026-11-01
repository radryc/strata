# Authentik reference deployment

`authentik.yaml` is a self-contained development Authentik deployment used by
the Kubernetes SSO example in
[`docs/access-and-login.md`](../../docs/access-and-login.md).

It creates:

- PostgreSQL and Redis;
- the Authentik server and worker;
- an OAuth2/OIDC provider for the `monofs` client;
- the development admin account.

## Development credentials

These are **development-only** fixed values:

```text
Authentik URL : http://127.0.0.1:29020
Admin user    : akadmin
Admin pass    : password
Admin email   : admin@example.com
OIDC client   : monofs
Client secret : monofs-oidc-secret
```

Do not use them in production. Replace the secrets in `authentik.yaml` or use a
managed identity provider.

## Apply

The local kind bootstrap applies this automatically. To apply it by hand:

```bash
kubectl apply -f bootstrap/auth/authentik.yaml
kubectl -n authentik rollout status deploy/authentik-server --timeout=360s
kubectl -n authentik rollout status deploy/authentik-worker --timeout=180s
kubectl -n authentik port-forward svc/authentik 29020:9000
```

Open <http://127.0.0.1:29020> and sign in as `akadmin` / `password`.

## Add a user

```bash
./scripts/create-authentik-user.sh \
  --username alice \
  --email alice@example.com \
  --password 'choose-a-password' \
  --grant maintainer \
  --partition onboarding-app
```

The `--grant` flag patches the Guardian/MonoFS `MONOFS_AUTHZ_GRANTS_JSON` and
restarts the deployments. The email is what authorization grants match.
