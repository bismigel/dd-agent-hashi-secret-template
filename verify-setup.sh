#!/usr/bin/env bash
# Verify the Datadog Agent + native HashiCorp Vault template.
set -euo pipefail

cd "$(dirname "$0")"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
else
  COMPOSE=(docker-compose)
fi

echo "CHECK: Verifying Datadog Agent + native HashiCorp Vault setup..."

required_files=(
  "docker-compose.yml"
  "Dockerfile"
  "datadog.yaml"
  "conf.d/http_check.yaml"
  "status-api-checks.json"
  ".env.example"
)

for file in "${required_files[@]}"; do
  if [ -f "$file" ]; then
    echo "  [OK] $file"
  else
    echo "  [FAIL] $file (missing)"
    exit 1
  fi
done

if [ ! -f .env ]; then
  cp .env.example .env
  echo "  WARN: .env created from .env.example (dummy Datadog key)"
fi

echo "DOCKER: Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "  [FAIL] docker not found"
  exit 1
fi
echo "  [OK] docker"

if [ -z "$("${COMPOSE[@]}" ps -q 2>/dev/null)" ]; then
  echo "  INFO: Services are not running."
  echo "     Start with: ${COMPOSE[*]} up --build -d"
  exit 0
fi

echo "SERVICES: Checking services..."
"${COMPOSE[@]}" ps

echo "VAULT: Checking Vault..."
curl -fsS http://localhost:8200/v1/sys/health >/dev/null
echo "  [OK] Vault is responding on localhost:8200"

echo "AUTH: Checking status-api basic auth..."
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/api/detail)
if [ "$code" != "401" ]; then
  echo "  [FAIL] expected 401 without credentials, got $code"
  exit 1
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -u testuser:testpass \
  http://localhost:8080/api/detail)
if [ "$code" != "200" ]; then
  echo "  [FAIL] expected 200 with testuser:testpass, got $code"
  exit 1
fi
echo "  [OK] 401 without credentials, 200 with Vault credentials"

echo "AGENT: Checking the Datadog Agent..."
docker exec datadog-agent agent status >/dev/null
echo "  [OK] Agent is responding"
docker exec datadog-agent grep -q 'secret_backend_type: hashicorp.vault' \
  /etc/datadog-agent/datadog.yaml
if docker exec datadog-agent grep -Eq '^[[:space:]]*secret_backend_command[[:space:]]*:' \
  /etc/datadog-agent/datadog.yaml; then
  echo "  [FAIL] datadog.yaml still uses the old secret_backend_command"
  exit 1
fi
echo "  [OK] Native hashicorp.vault backend is configured"
docker exec datadog-agent agent status | grep -q 'status-api detail (Vault basic auth)'
echo "  [OK] status-api http_check instance is loaded"

echo
echo "[OK] Verification complete"
echo
echo "Rotation test (restart the Agent with DD_LOG_LEVEL=debug so the request"
echo "lines are visible):"
echo "  DD_LOG_LEVEL=debug ${COMPOSE[*]} up -d datadog-agent"
echo "  docker exec -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root vault \\"
echo "    vault kv put secret/http_check username=testuser password=wrongpass"
echo "  sleep 75"
echo "  docker logs datadog-agent 2>&1 | grep 'GET /api/detail.*401'"
echo "  docker exec -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN=root vault \\"
echo "    vault kv put secret/http_check username=testuser password=testpass"
