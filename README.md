# Datadog Agent + Native HashiCorp Vault

A minimal, working template for the Datadog Agent's **native**
`hashicorp.vault` secret backend.

Vault holds the credentials. The Agent resolves `ENC[...]` handles itself, and
the resolved credentials are used by an `http_check` against the status-api
basic-auth endpoint (`/api/detail`). No custom secret-backend script is needed.

Verified with:

- Datadog Agent **7.85.0**
- HashiCorp Vault **1.21.2** (dev mode)
- status-api (public GHCR image)

> See [learnings.md](learnings.md) for the tested behavior, version differences,
> and gotchas. The old `auth_token`/7.74.1 workaround is gone.

## Architecture

```text
+-------------------+        +-------------------+        +------------------+
|   Datadog Agent   |<------>|  HashiCorp Vault  |<------>|   KV v2 secrets  |
|  7.85.0           | native |  1.21.2 (dev)     |        | datadog,         |
|                   | backend|                   |        | http_check       |
+---------+---------+        +-------------------+        +------------------+
          |
          | http_check with Vault-provided basic auth
          v
+-------------------+
|    status-api     |
| /api/detail       |  401 without creds, 200 with them
+-------------------+
```

## Quick start

```bash
cp .env.example .env
# Optional: put a real Datadog API key in .env. A dummy key is fine for tests.

docker compose up --build -d

# status-api basic auth
curl -i http://localhost:8080/api/detail                       # 401
curl -i -u testuser:testpass http://localhost:8080/api/detail  # 200

# Agent status
docker exec datadog-agent agent status

# Verify the whole template
./verify-setup.sh
```

## What this proves

- The Agent reads the Datadog API key and the status-api credentials from Vault.
- The `http_check` reaches status-api with `200` using those credentials.
- Removing/altering the Vault secret makes the check fail (`401`).
- Restoring the secret makes the check recover, without restarting the Agent.
- The Agent does **not** need an `auth_token` file to talk to Vault.

## Datadog site (region)

This repo defaults to **US5**: `site: us5.datadoghq.com` and
`DD_SITE=us5.datadoghq.com`. Set `DD_SITE` in `.env` to the region your
Datadog organization uses:

| Region | Site |
| --- | --- |
| US1 | `datadoghq.com` |
| US3 | `us3.datadoghq.com` |
| US5 | `us5.datadoghq.com` |
| EU | `datadoghq.eu` |
| AP1 | `ap1.datadoghq.com` |

The API key must be from the same region. The site is visible in your Datadog
URL, for example `app.us5.datadoghq.com` -> `us5.datadoghq.com`. When running
the Agent outside Compose, also update `site:` in `datadog.yaml`.

To send metrics to the real Datadog backend:

1. Set a real API key and your site in `.env`:

   ```bash
   VAULT_DD_API_KEY=<real-api-key>
   DD_SITE=<your-site>
   ```

2. Recreate the Agent so it picks up `DD_SITE`:

   ```bash
   docker compose up -d --force-recreate datadog-agent
   ```

3. Update the existing Vault secret. `startup.sh` only creates missing
   secrets, so changing `.env` alone does not update an already-seeded key:

   ```bash
   set -a; . ./.env; set +a
   docker exec -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root vault \
     vault kv put secret/datadog api_key="$VAULT_DD_API_KEY"
   ```

   Wait for `secret_refresh_interval` (60s) or restart the Agent.

4. Check the Agent logs:

   ```bash
   docker logs datadog-agent 2>&1 | grep -i -E '403|invalid api key'
   ```

   No `403` means the key and site match.

5. In Datadog, look for:
   - `datadog.agent.running`
   - `datadog.http_check.status` with `service:status-api`
   - the `status-api detail (Vault basic auth)` service check

## Vault layout

`scripts/startup.sh` creates these KV v2 secrets **only if they are missing**:

| Path | Keys |
| --- | --- |
| `secret/datadog` | `api_key` |
| `secret/http_check` | `username=testuser`, `password=testpass` |

Because existing secrets are left alone, rotating a secret in Vault survives an
Agent restart.

## Native Agent configuration

`datadog.yaml`:

```yaml
api_key: ENC[/secret/datadog;api_key]

secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: http://vault:8200
  vault_token: root   # dev only

secret_refresh_interval: 60
```

`conf.d/http_check.yaml`:

```yaml
instances:
  - name: status-api detail (Vault basic auth)
    url: http://status-api:8080/api/detail
    username: ENC[/secret/http_check;username]
    password: ENC[/secret/http_check;password]
```

Secret handle format is `ENC[/mount/path;key]`. The native backend supports KV
v1 and v2.

### `auth_token` is not the Vault token

`/etc/datadog-agent/auth_token` is the Agent's **IPC auth token**. The Agent
creates it automatically with a random value. It is not the Vault token, and
this template does not mount or pre-create it.

`vault_token` is a **literal static token**, not a file path.

## Vault policy for KV v2

```hcl
path "secret/data/*" {
  capabilities = ["read"]
}

# The Agent reads mount information to detect the KV engine version.
# Without this, it assumes KV v1 and KV v2 reads fail.
path "sys/mounts" {
  capabilities = ["read"]
}
```

## Secret rotation

`secret_refresh_interval` makes the Agent re-resolve secrets without a restart.
Runtime refresh of secrets used by file-based checks is available in Agent
7.76+. This template pins 7.85.0.

Manual check:

```bash
# Keep debug logs on so the http_check request lines are visible.
DD_LOG_LEVEL=debug docker compose up -d datadog-agent

docker exec -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root vault \
  vault kv put secret/http_check username=testuser password=wrongpass
sleep 75
docker logs datadog-agent 2>&1 | grep 'GET /api/detail.*401'

docker exec -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root vault \
  vault kv put secret/http_check username=testuser password=testpass
sleep 75
docker logs datadog-agent 2>&1 | grep 'GET /api/detail.*200'
```

## Verification

```bash
./verify-setup.sh
```

The script checks:

- required files
- Docker/Compose availability
- Vault health
- status-api `401` without credentials and `200` with credentials
- Agent response and native backend config
- the `status-api detail (Vault basic auth)` check instance

## Production notes

The compose setup uses Vault `-dev` mode with a root token. Do not use it in
production.

### Authentication

Kubernetes (recommended when Vault and the Agent are in Kubernetes):

```yaml
secret_backend_type: hashicorp.vault
secret_backend_config:
  vault_address: https://vault.example.com:8200
  vault_session:
    vault_auth_type: kubernetes
    vault_kubernetes_role: datadog-agent
```

AppRole (when Kubernetes auth is not available):

```yaml
secret_backend_config:
  vault_address: https://vault.example.com:8200
  vault_session:
    vault_role_id: <role-id>
    vault_secret_id: <secret-id>
```

Environment-based token (dev/simple deployments):

```yaml
secret_backend_config:
  vault_session:
    implicit_auth: "true"
```

with `VAULT_ADDR` and `VAULT_TOKEN` in the environment. On Agent 7.85.0 the
value must be the string `"true"`; a YAML boolean (`true`) fails with an
`expected type 'string'` error.

### TLS

```yaml
secret_backend_config:
  vault_address: https://vault.example.com:8200
  vault_tls_config:
    ca_cert: /etc/datadog-agent/certs/ca.pem
    client_cert: /etc/datadog-agent/certs/client.pem
    client_key: /etc/datadog-agent/certs/client-key.pem
```

### Agent version

- Native Vault backend: Agent 7.70+
- Runtime refresh for check secrets: Agent 7.76+
- This template pins `datadog/agent:7.85.0`

## Migration notes

This template previously pinned Agent 7.74.1 and required a
`secrets/auth_token` file plus `chmod 666`. That was a workaround for the
Agent's IPC auth token, not Vault authentication. The current template:

- pins 7.85.0
- removes the `auth_token` mount and `chmod 666`
- uses `hashicorp/vault:1.21.2` instead of the nonexistent `vault:latest`
- adds `secret_refresh_interval: 60`
- makes `startup.sh` idempotent
- uses status-api `/api/detail` as the basic-auth target
- does not overwrite rotated secrets on restart

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `could not resolve secret handle(s)` | Check `VAULT_TOKEN`, `vault_address`, the path/key in `ENC[...]`, and that the Agent can reach Vault. |
| `Invalid path for a versioned K/V secrets engine` | The Agent assumed KV v1. Grant `read` on `sys/mounts`. |
| status-api returns `401` in the check | The Vault credentials are wrong, or the Agent has not refreshed them yet. Check `secret_refresh_interval`. |
| Rotation is not picked up | Agent older than 7.76, or `secret_refresh_interval` is not set. |
| `expected type 'string'` for `implicit_auth` | Use `implicit_auth: "true"` (quoted) on 7.85.0. |
| Vault container is unhealthy | Use the `hashicorp/vault` image and a `wget` healthcheck; the image does not have `curl`. |

## References

- [Datadog Secrets Management](https://docs.datadoghq.com/agent/configuration/secrets-management/)
- [HashiCorp Vault documentation](https://developer.hashicorp.com/vault/docs)
- [Datadog Agent image](https://hub.docker.com/r/datadog/agent)
- [learnings.md](learnings.md) — tested behavior and gotchas
