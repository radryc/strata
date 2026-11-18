# Access and login

Strata has two access modes:

| Mode | Where | How it works |
|---|---|---|
| Local developer login | kind stack | Authentik OIDC for Guardian, Doctor, and MonoFS |
| Production SSO | Kubernetes / AWS | OIDC through your identity provider (Authentik, Dex, Keycloak, Cognito) |

The local stack uses the same Authentik OIDC flow as the Kubernetes example.
The direct CLI endpoints remain available for `guardianctl` and local debugging.

Guardian, Doctor, and MonoFS all expose `/auth/login`, which starts the
Authentik browser flow. Doctor and MonoFS also redirect anonymous browser
visits to it. Guardian keeps its read-only UI reachable without a session so
the in-cluster `/health` probe and the local bootstrap keep working; UI
mutations still require a login.

---

## Local kind login (Authentik)

`./scripts/bootstrap.sh up` deploys Authentik and points Guardian, MonoFS, and
Doctor at it. There is no separate local password to manage.

| Service | URL |
|---|---|
| Guardian | <http://127.0.0.1:28090> |
| Doctor | <http://127.0.0.1:28080> |
| MonoFS | <http://127.0.0.1:28081> |
| Authentik | <http://127.0.0.1:29020> |

The development admin account is:

```text
username: akadmin
password: password
email:    admin@example.com
```

`admin@example.com` is granted admin on all partitions by the bootstrap.

### Create a user and set the password

```bash
./scripts/create-authentik-user.sh \
  --username alice \
  --email alice@example.com \
  --password 'choose-a-password'
```

Create the user first, then add the matching subject to the access policy
(`access/envs/<env>.yaml`) and publish it:

```bash
guardianctl access lint    --file access/envs/dev.yaml
guardianctl access publish --file access/envs/dev.yaml --env dev
```

The email is the subject the access policy matches. `--grant` on the user
script prints the exact YAML entry to add. The script can also add Authentik
groups with `--groups`.

### CLI access

The Guardian CLI uses the direct API endpoint:

```bash
guardianctl auth login \
  --issuer http://127.0.0.1:29020/application/o/monofs/ \
  --client-id monofs --client-secret monofs-oidc-secret
```

Then `guardianctl --guardian-url http://127.0.0.1:18090 ...` works with the
cached token. MonoFS gRPC is on `127.0.0.1:19090`.

The example application remains at <http://127.0.0.1:18088>.

---

## Kubernetes with Authentik (example)

The public reference deployment in
[`bootstrap/auth/authentik.yaml`](../bootstrap/auth/authentik.yaml) provides a
real OIDC provider for local or Kubernetes testing. It is a development
deployment with fixed credentials; replace them before production.

### 1. Deploy Authentik

```bash
kubectl apply -f bootstrap/auth/authentik.yaml
kubectl -n authentik rollout status deploy/authentik-server --timeout=360s
kubectl -n authentik rollout status deploy/authentik-worker --timeout=180s
kubectl -n authentik port-forward svc/authentik 29020:9000
```

Open <http://127.0.0.1:29020> and sign in as:

```text
username: akadmin
password: password
email:    admin@example.com
```

The blueprint creates an OAuth2/OIDC client:

```text
client_id:     monofs
client_secret: monofs-oidc-secret
issuer:        http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/
```

### 2. Create a user and set the password

```bash
./scripts/create-authentik-user.sh \
  --username alice \
  --email alice@example.com \
  --password 'choose-a-password'
```

Add the matching subject to `access/envs/<env>.yaml` and publish it with
`guardianctl access publish` (or run the user script with `--grant` to print the
YAML entry). The email is the subject the access policy matches. The script can
also add Authentik groups with `--groups`.

### 3. Point Guardian at Authentik

```bash
kubectl -n strata set env deploy/guardiand \
  MONOFS_OIDC_ISSUER=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/ \
  MONOFS_OIDC_AUDIENCE=monofs \
  MONOFS_OIDC_CLIENT_ID=monofs \
  MONOFS_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  MONOFS_OIDC_REDIRECT_URL=http://127.0.0.1:28090/auth/callback \
  MONOFS_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \
  GUARDIAN_REQUIRE_UI_AUTH=true

kubectl -n strata rollout restart deploy/guardiand
kubectl -n strata rollout status deploy/guardiand --timeout=120s
```

Open <http://127.0.0.1:28090/auth/login> to sign in; Authentik returns to
Guardian with a session cookie. The read-only Guardian UI stays reachable
without a session by default so the `/health` probe keeps passing. UI mutations
require a login because `GUARDIAN_REQUIRE_UI_AUTH=true`. To also gate browser
reads, set `GUARDIAN_REQUIRE_UI_AUTH=true` and add `/health` to Guardian's auth
exemptions (or change the probe path).

### 4. Point MonoFS at Authentik

The MonoFS router takes the issuer and audience as CLI flags, not environment
variables. Patch its arguments once:

```bash
kubectl -n strata patch deploy/monofs-router --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--oidc-issuer=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--oidc-audience=monofs"}
]'

kubectl -n strata set env deploy/monofs-router \
  MONOFS_OIDC_CLIENT_ID=monofs \
  MONOFS_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  MONOFS_ROUTER_OIDC_REDIRECT_URL=http://127.0.0.1:28081/auth/callback \
  MONOFS_ROUTER_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \

kubectl -n strata rollout restart deploy/monofs-router
kubectl -n strata rollout status deploy/monofs-router --timeout=120s
```

Open <http://127.0.0.1:28081>; MonoFS redirects to Authentik, and after login
returns to the UI.

### 5. Point Doctor at Authentik

```bash
kubectl -n strata set env deploy/doctor-query \
  DOCTOR_AUTH_REQUIRE=false \
  DOCTOR_OIDC_ISSUER=http://authentik.authentik.svc.cluster.local:9000/application/o/monofs/ \
  DOCTOR_OIDC_AUDIENCE=monofs \
  DOCTOR_OIDC_CLIENT_ID=monofs \
  DOCTOR_OIDC_CLIENT_SECRET=monofs-oidc-secret \
  DOCTOR_OIDC_REDIRECT_URL=http://127.0.0.1:28080/auth/callback \
  DOCTOR_OIDC_AUTH_URL=http://127.0.0.1:29020/application/o/authorize/ \
  DOCTOR_OIDC_REQUIRE_LOGIN=true

kubectl -n strata rollout restart deploy/doctor-query
kubectl -n strata rollout status deploy/doctor-query --timeout=120s
```

Open <http://127.0.0.1:28080>; Doctor redirects to Authentik, and after login
returns to the UI.

### Authentik redirect URLs

The reference blueprint already includes these redirect URIs:

```text
http://127.0.0.1:28090/auth/callback   # Guardian
http://127.0.0.1:28081/auth/callback   # MonoFS
http://127.0.0.1:28080/auth/callback   # Doctor
```

For a real hostname, add the matching `https://.../auth/callback` URI to the
Authentik provider and update the `*_OIDC_REDIRECT_URL` values.

---

## AWS Cognito login

The public AWS CDK stack enables Cognito SSO by default
(`deploySSO=true`). `./deploy.sh` generates a password unless you set one:

```bash
export AWS_PROFILE=my-profile
export AWS_REGION=eu-west-1
export STRATA_ADMIN_PASSWORD='choose-a-password'

cd ../aws
./deploy.sh --with-pusher -y
```

This creates the `strata` Cognito user pool and three demo users:

| Username | Email |
|---|---|
| `akadmin` | `admin@example.com` |
| `usera` | `usera@example.com` |
| `userb` | `userb@example.com` |

They share the password from `STRATA_ADMIN_PASSWORD`. Sign in at the
`AppUrl` (Guardian/MonoFS) or `DoctorUrl` output from CloudFormation.

### Create or reset a Cognito user

```bash
POOL_ID="$(aws cloudformation describe-stacks \
  --stack-name StrataStack \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoUserPoolId'].OutputValue" \
  --output text)"

aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username you@example.com \
  --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username you@example.com \
  --password 'choose-a-password' \
  --permanent
```

To grant the new user access, add the matching subject to the repo-managed
access policy (`access/envs/<env>.yaml`) and publish it. The policy is the
single runtime authorization source for Guardian, MonoFS, and Doctor. The
default policy includes `admin@example.com` as a global admin and the demo
division users as scoped viewers.

---

## Break-glass and API tokens

For automation and recovery, MonoFS/Guardian accept a bearer token.

Local kind:

```bash
source .strata/dev.env
guardianctl --monofs-router 127.0.0.1:19090 \
  --monofs-token "$MONOFS_TOKEN" partition list
```

Kubernetes:

```bash
kubectl -n strata get secret strata-secrets \
  -o jsonpath='{.data.MONOFS_TOKEN}' | base64 -d
```

`guardianctl` uses the same token:

```bash
guardianctl --monofs-router 127.0.0.1:19090 --monofs-token "$MONOFS_TOKEN" partition list
```

Rotate the token by updating the Kubernetes Secret and restarting the
Guardian/MonoFS workloads.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Authentik login page does not load | Check `kubectl -n authentik get pods` and the `29020` port-forward |
| Login succeeds but Guardian/Doctor shows anonymous | Confirm the user email has a grant in the published access policy |
| 401 on a Guardian mutation | Sign in through `/auth/login`, or call the API with a bearer token |
| OIDC login redirects but returns 403 | The user is authenticated but the access policy grants no matching scope/role |
| Cognito user cannot sign in | Run `admin-set-user-password --permanent`; self-signup is disabled |
