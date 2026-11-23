# Production Hardening Guide

Strata ships with developer-friendly defaults for local `kind` testing. Before
running in shared, regulated, or production environments, enable the hardening
controls below across each plane.

---

## 1. Authentication & Access Control

### MonoFS
- Enforce gRPC and HTTP authorization with a compiled access policy from the separate `access` repository (clone it next to `strata`, then compile `../access/envs/prod.yaml` to `access.yaml`):
  - Set `--access-enforce` (or `MONOFS_ACCESS_ENFORCE=true`) and point `--access-policy-file` / `MONOFS_ACCESS_POLICY_FILE` at the compiled bundle on `monofs-router` and `monofs-server`.
  - OIDC tokens must carry a non-empty `sub` or `client_id` claim (`OIDCVerifier.Verify` rejects empty-identity tokens).
  - Break-glass tokens (`NewBreakGlassVerifier`) use `ClientID: "break-glass-admin"` and are recognized by `Policy.IsAdmin` in `pkg/authz/policy`.
- Use distinct tokens for `--native-auth-token`, `--internal-token`, and break-glass access rather than reusing a single `MONOFS_TOKEN`.

### Guardian
- Require OIDC authentication and policy enforcement on `guardiand`:
  ```text
  GUARDIAN_REQUIRE_UI_AUTH=true          # or --require-ui-auth
  GUARDIAN_ALLOW_LOOPBACK_ANONYMOUS=false
  GUARDIAN_ACCESS_POLICY_PATH=/etc/strata/access.yaml
  GUARDIAN_ACCESS_ENFORCE=true
  GUARDIAN_TRUSTED_ORIGINS=https://guardian.example.com
  GUARDIAN_ENABLE_HSTS=true
  ```
- Requests carrying `X-Forwarded-For` or `Forwarded` headers are never treated as loopback for anonymous bypass, so placing Guardian behind a reverse proxy cannot spoof localhost access.
- Set `GUARDIAN_ACCESS_POLICY_TOKEN` (and `ClientConfigToken`) so `/api/m2m/*` and `/api/access/policy` require bearer authentication.

### Doctor
- Disable Sentinel's local-dev bypass and enable OIDC + policy enforcement:
  ```text
  DOCTOR_SENTINEL_AUTH_ALLOW_ALL=false
  DOCTOR_OIDC_ISSUER=https://idp.example.com/...
  DOCTOR_OIDC_AUDIENCE=doctor
  DOCTOR_ACCESS_MODE=enforce
  DOCTOR_ACCESS_ENFORCE_LOGS=true
  DOCTOR_ACCESS_ENFORCE_TRACES=true
  DOCTOR_QUERY_ALLOWED_TENANTS=<tenant-allowlist>
  ```

### Agent
- Restrict CORS to explicit UI origins (`CORS_ALLOWED_ORIGINS=["https://agent.example.com"]`; if `"*"` is configured, `allow_credentials` is automatically disabled).
- Terminate TLS at the ingress/proxy so `lagent_sso` cookies are issued with `Secure=True`.
- `OIDCTokenProvider` validates `id_token` `iss`, `aud` (`+ azp`), `exp`, and `nonce` claims when returned by the IdP.
- Keep `LLM_HYBRID_ENABLED=false` (or use a private/in-cluster LLM endpoint) in regulated environments; when calling external LLM URLs, `redact_sensitive_text` strips private keys, Bearer tokens, AWS `AKIA...` keys, `sk-...` keys, SSNs, and PANs.
- `workspace_commit` and `workspace_push` remain gated behind `mutating=True`, and `resolve_approval` binds pending approvals to `session_id`.

---

## 2. Transport Security (TLS / mTLS / Timeouts)

- **Doctor ↔ MonoFS**: Set `DOCTOR_MONOFS_TLS_REQUIRE=true` along with `DOCTOR_MONOFS_TLS_CA` (and `DOCTOR_MONOFS_TLS_CERT` / `DOCTOR_MONOFS_TLS_KEY` for mTLS), or use the shared `STRATA_TLS_*` client settings.
- **Doctor Sentinel**: Enable TLS with `DOCTOR_SENTINEL_TLS_CERT_FILE` and `DOCTOR_SENTINEL_TLS_KEY_FILE`.
- **Guardian Pushers (`aws` & `gcp`)**: Always provide TLS certificate/key flags on non-loopback addresses (the `gcp` pusher uses `--read-tls-cert` / `--read-tls-key` / `--read-allow-plaintext`; the `aws` pusher uses `--awsread-tls-cert` / `--awsread-tls-key` / `--awsread-allow-plaintext`). Non-loopback plaintext HTTP is rejected even when a bearer token is configured, unless the matching allow-plaintext flag is explicitly passed.
- **HTTP & Proxy Timeouts**:
  - `guardiand`, `doctor-sentinel`, and `lb` (`registry`/`edge`) enforce `ReadHeaderTimeout` (10s), `ReadTimeout` (30s), `WriteTimeout` (60s), and `IdleTimeout` (120s).
  - `lb` TCP proxy enforces a 5-minute idle read/write deadline and sanitizes `Host` headers in `/services`.
- **Webhook Replay Protection**: Guardian webhook notifications include `X-Guardian-Timestamp` (Unix seconds) and `X-Guardian-Signature-V2: sha256=<hmac(timestamp + "." + body)>` alongside `X-Guardian-Signature`; receivers should verify `V2` and reject stale timestamps.

---

## 3. SSRF, Privacy/PII, & Audit Logging

- **SSRF Protection (`doctor` `netguard`)**:
  - Keep `DOCTOR_BACKEND_ALLOW_PRIVATE=false` and `DOCTOR_SENTINEL_WEBHOOK_ALLOW_PRIVATE=false` with `DOCTOR_SENTINEL_WEBHOOK_REQUIRE_HTTPS=true`; scope query backends with `DOCTOR_BACKEND_ALLOWED_HOSTS`.
  - When enabled without an explicit host allowlist, `netguard` resolves DNS hostnames and fails closed if any resolved IP is loopback, link-local/cloud-metadata (`169.254.0.0/16`), RFC1918, or non-`http`/`https`.
- **PII & PCI Tokenization (`doctor` `privacy`)**:
  - Configure a high-entropy `DOCTOR_PRIVACY_HMAC_KEY`.
  - `privacy.Engine` redacts/tokenizes sensitive keys (`pan`, `card_number`, `cvv`, `cvc`, `ssn`, `tin`, `iban`, `routing_number`, `pin`, `dob`, `passport`, `phone`, plus credential/token keys), embedded JWTs in log lines, emails, IPv4 addresses, SSNs, and Luhn-validated PANs.
- **Audit Logging (`doctor` `audit`)**:
  - Set `DOCTOR_AUDIT_LOG` to a persistent path; `doctor-query` logs both state mutations and telemetry read queries (`/v1/logs`, `/v1/traces`, `/v1/sql/query`, `/loki/api/v1/query*`) and emits a structured fallback warning if the audit file cannot be opened.

---

## 4. Telemetry Encryption, Executor Isolation, & Container Builds

- **Telemetry Encryption at Rest**: Set `MONOFS_TELEMETRY_ENCRYPTION=envelope` (write + read) with managed keys through `MONOFS_TELEMETRY_ENCRYPTION_KEYS_FILE` or `MONOFS_TELEMETRY_ENCRYPTION_KEYS_JSON`, and `MONOFS_TELEMETRY_ENCRYPTION_MODE=enforce` to reject plaintext log/trace chunks on read.
- **Worker Executor Isolation**: `monofs-pipeline-worker` filters the host environment through an explicit safe allowlist (path/home/temp, locale, proxy, Go module cache, and TLS bundle variables) instead of leaking worker tokens to build subprocesses.
- **Container & Supply-Chain Builds**:
  - `guardian/Dockerfile.pusher-gcp` requires a non-empty `TOFU_SHA256` build arg and fails the build if checksum verification is omitted.
  - `guardian/Dockerfile.pusher-aws` pins `aws-cdk@2`.
  - Use immutable image digests rather than `:dev`/`:latest` tags in production Kubernetes manifests, and replace the bootstrap `strata-guardian-pusher` ClusterRole/ClusterRoleBinding with namespace/resource-scoped Roles.
