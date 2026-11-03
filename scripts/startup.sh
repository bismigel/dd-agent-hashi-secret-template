#!/bin/sh
# Prepare Vault for the demo, then start the Datadog Agent.
#
# The script is idempotent: it only creates secrets that are missing, so
# restarting the Agent does not overwrite a rotated secret.
set -eu

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

echo "Waiting for Vault at ${VAULT_ADDR}..."
attempt=1
max_attempts=30
while ! curl -fsS "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; do
  if [ "${attempt}" -ge "${max_attempts}" ]; then
    echo "ERROR: Vault did not become ready after ${max_attempts} attempts" >&2
    exit 1
  fi
  echo "  attempt ${attempt}/${max_attempts}: not ready, retrying in 2s..."
  sleep 2
  attempt=$((attempt + 1))
done
echo "Vault is ready."

# Vault -dev already mounts secret/; ignore the error if it exists.
curl -sS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"type":"kv-v2"}' \
  "${VAULT_ADDR}/v1/sys/mounts/secret" >/dev/null 2>&1 || true

secret_exists() {
  path="$1"
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${path}" 2>/dev/null || true)
  [ "${code}" = "200" ]
}

seed_secret() {
  path="$1"
  data="$2"
  if secret_exists "${path}"; then
    echo "  secret/${path} already exists; leaving it unchanged"
    return 0
  fi
  curl -fsS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -d "{\"data\":${data}}" \
    "${VAULT_ADDR}/v1/secret/data/${path}" >/dev/null
  echo "  secret/${path} created"
}

DD_KEY="${VAULT_DD_API_KEY:-dummy-datadog-api-key}"
if [ "${DD_KEY}" = "dummy-datadog-api-key" ]; then
  echo "WARNING: VAULT_DD_API_KEY is not set; using a dummy key." >&2
  echo "         The Agent will resolve it, but Datadog will reject metrics." >&2
fi

echo "Seeding demo secrets (only if missing)..."
seed_secret "datadog" "{\"api_key\":\"${DD_KEY}\"}"
seed_secret "http_check" '{"username":"testuser","password":"testpass"}'

# Podman host-network users can set USE_LOCALHOST=1.
if [ "${USE_LOCALHOST:-0}" = "1" ]; then
  echo "USE_LOCALHOST=1: rewriting Vault and status-api URLs to localhost"
  sed -i 's#vault_address: http://vault:8200#vault_address: http://localhost:8200#' \
    /etc/datadog-agent/datadog.yaml
  sed -i 's/status-api:8080/localhost:8080/g' /etc/datadog-agent/conf.d/http_check.yaml
fi

echo "Starting Datadog Agent..."
exec "$@"
