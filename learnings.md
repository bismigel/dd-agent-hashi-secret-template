# Learnings — native Datadog Agent + HashiCorp Vault

What was actually verified while modernizing this template. Several claims in
older versions of this repo (and in the Agent 7.74.1 docs) turned out to be
wrong or version-dependent.

## Test environment

| Component | Version |
| --- | --- |
| Datadog Agent | `datadog/agent:7.85.0` |
| HashiCorp Vault | `hashicorp/vault:1.21.2` (`-dev`) |
| status-api | `ghcr.io/bismigel/status-api:latest` |
| Also compared | `datadog/agent:7.74.1` |

## Verified behavior

### 1. The native backend works

```yaml
api_key: ENC[/secret/datadog;api_key]

secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: http://vault:8200
  vault_token: root
```

The native backend is built in (7.70+) and supports KV v1 and v2. The custom
`secret_backend_command`/`secret_backend.py` path is the older "Option 3"
approach.

### 2. `/etc/datadog-agent/auth_token` is not the Vault token

- It is the Agent's **IPC auth token**.
- The Agent creates it automatically with a random 64-hex value.
- It is not needed for Vault. Both 7.74.1 and 7.85.0 started and resolved
  Vault secrets without an `auth_token` mount.
- Do not mount a static `root` value there and do not `chmod 666` it.

### 3. `vault_token` is a literal, not a file path

The docs describe `vault_token` as a "static Vault token". In the 7.85.0 test,
pointing it at a file path did not work; the Agent failed to resolve secrets.
Use one of:

- `vault_token: <literal>` for dev/demo
- `vault_session` with Kubernetes/AppRole for production
- `vault_session: { implicit_auth: "true" }` + `VAULT_TOKEN` env

### 4. `implicit_auth` is nested and must be a string on 7.85.0

The docs table lists `implicit_auth` under "All `vault_session` options". It is
not a top-level `secret_backend_config` field.

This failed on 7.85.0:

```yaml
secret_backend_config:
  vault_session:
    implicit_auth: true
```

with:

```text
'vault_session.implicit_auth' expected type 'string', got unconvertible type 'bool'
```

This worked:

```yaml
secret_backend_config:
  vault_session:
    implicit_auth: "true"
```

with `VAULT_ADDR` and `VAULT_TOKEN` in the environment. `vault_address` can be
omitted when `VAULT_ADDR` is set.

### 5. KV v2 needs `sys/mounts` read

```hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}
```

Without `sys/mounts`, the Agent assumes KV v1. A KV v2 path then fails with
`Invalid path for a versioned K/V secrets engine`. Reproduced with a token that
had only `secret/data/*` read; adding `sys/mounts` fixed it.

### 6. Runtime refresh works on 7.85.0, not 7.74.1

With `secret_refresh_interval: 15`:

- **7.85.0**: a rotated `secret/http_check` password was picked up, the check
  logged `401`, and it recovered after restoring the password.
- **7.74.1**: stayed on the old credential and kept returning `200` after 50+
  seconds.

The docs say check-secret refresh is available in 7.76+. Pin a current Agent if
rotation matters.

### 7. Startup must be idempotent

The old `startup.sh` wrote `testuser`/`testpass` to `secret/http_check` on every
container start. That silently undid rotation:

- set the password to `wrongpass` (Vault version 8)
- restart the Agent
- the password was `testpass` again (version 9)

The current script only creates secrets that do not exist.

### 8. Vault image details

- `vault:latest` does **not** exist on Docker Hub. Use
  `hashicorp/vault:1.21.2` (or another pinned tag).
- The official Vault image has `wget` (busybox), not `curl`. A healthcheck using
  `curl` fails.
- The Datadog Agent image has `curl`, so `startup.sh` can use it.

### 9. Prefixed `ENC[...]` in headers (observed while testing header auth)

While testing additional header-based checks, this did **not** resolve on
7.85.0:

```yaml
Authorization: "Bearer ENC[/secret/oauth;access_token]"
```

The check repeatedly returned `401`. Storing the full header value in Vault and
using the handle as the whole value worked:

```yaml
# Vault: secret/oauth { authorization = "Bearer test-oauth-token-12345" }
Authorization: "ENC[/secret/oauth;authorization]"
```

This template's basic-auth check uses the `username`/`password` fields, where
the handle is already the whole value, so it is not affected. Re-test prefixed
handles on your Agent version before relying on them.

### 10. Test-harness gotcha: `pipefail` + `grep -q`

Polling `docker logs | grep -q` under `set -o pipefail` produced false
negatives: `grep -q` exits early, the log producer gets `SIGPIPE`, and the
pipeline returns non-zero even though the pattern matched.

Use:

```bash
docker logs container 2>&1 | grep -- "$pattern" >/dev/null
```

instead of `grep -q`.

### 11. `agent status --json` may not expose `network.http.can_connect`

On 7.85.0, the `http_check` runner showed `Metric Samples: 3`, but
`aggregatorStats.ChecksMetricSample` was empty in `agent status --json`. The
rotation test therefore uses the debug HTTP log line:

```text
http://localhost:8080 "GET /api/detail HTTP/1.1" 200 226
http://localhost:8080 "GET /api/detail HTTP/1.1" 401 13
```

Set `DD_LOG_LEVEL=debug` for the test only; keep `INFO` in production.

### 12. The Kubernetes/Docker Agent container still requires DD_API_KEY

The upstream `datadog/agent` container's s6 entrypoint checks for `DD_API_KEY`
before the Agent starts. Even with `api_key: ENC[...]` in `datadog.yaml`, the
container exits with:

```text
You must set either a DD_API_KEY or DD_DELEGATED_AUTH_ORG_UUID environment
variable to run the Datadog Agent container.
```

Set the environment variable to the same handle:

```yaml
env:
  - name: DD_API_KEY
    value: "ENC[/secret/datadog;api_key]"
```

The Agent resolves it through the configured secret backend. Verified on
7.85.0 with Vault Kubernetes auth: the entrypoint passed and the Agent resolved
the key from Vault. A real API key still has to match the configured Datadog
site; a dummy key produces the expected 403 from Datadog but does not affect
the Vault-backed `http_check`.

## Recommended configs

### Dev / demo

```yaml
api_key: ENC[/secret/datadog;api_key]

secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: http://vault:8200
  vault_token: root

secret_refresh_interval: 60
```

### Environment token

```yaml
secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_session:
    implicit_auth: "true"
```

```yaml
environment:
  VAULT_ADDR: http://vault:8200
  VAULT_TOKEN: root
```

### Kubernetes

```yaml
secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: https://vault.example.com:8200
  vault_session:
    vault_auth_type: kubernetes
    vault_kubernetes_role: datadog-agent
```

```sh
vault write auth/kubernetes/role/datadog-agent \
  bound_service_account_names=datadog-agent \
  bound_service_account_namespaces=default \
  policies=datadog-agent \
  ttl=1h
```

### AppRole

```yaml
secret_backend_config:
  vault_address: https://vault.example.com:8200
  vault_session:
    vault_role_id: <role-id>
    vault_secret_id: <secret-id>
```

## Test evidence

The native configuration in this template was verified end to end:

```text
[OK] 401 without credentials, 200 with Vault credentials
[OK] http_check reaches status-api with Vault credentials
[OK] Agent is configured for the native hashicorp.vault backend
[OK] status-api http_check instance is loaded
[OK] rotated password made the check fail with 401
[OK] check recovered after restore
```

## Open items

- The `implicit_auth` bool-vs-string mismatch looks like a documentation bug in
  the 7.85.0 docs. Re-test on newer Agents.
- Prefixed-header `ENC[...]` behavior may change; re-test before relying on it.
- `agent status --json` metric visibility may differ in newer Agents; the debug
  log check is a stable fallback.
- The `sys/mounts` requirement is confirmed; do not omit it from
  least-privilege policies.

## References

- [Datadog Secrets Management](https://docs.datadoghq.com/agent/configuration/secrets-management/)
- [HashiCorp Vault docs](https://developer.hashicorp.com/vault/docs)
- [Datadog Agent image](https://hub.docker.com/r/datadog/agent)
