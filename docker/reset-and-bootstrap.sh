#!/usr/bin/env bash
# reset-and-bootstrap.sh — clean DB + bootstrap tenant + catalog.
# Called by run-all.sh before each full gate run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
KB_URL="${KB_URL:-http://127.0.0.1:8081}"
KB_USER="${KB_USER:-admin}"
KB_PASS="${KB_PASS:-password}"

echo "=== tearing down any existing stack ==="
cd "$SCRIPT_DIR"
docker-compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true

echo "=== starting fresh stack ==="
docker-compose -f "$COMPOSE_FILE" up -d

echo "=== waiting for Kill Bill healthcheck ==="
for i in $(seq 1 60); do
  if curl -sS -o /dev/null -w "%{http_code}" -u "${KB_USER}:${KB_PASS}" "${KB_URL}/1.0/healthcheck" 2>/dev/null | grep -q 200; then
    echo "Kill Bill is up"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Kill Bill did not become healthy within 120s"
    docker-compose -f "$COMPOSE_FILE" logs killbill
    exit 1
  fi
  sleep 2
done

echo "=== creating INUA tenant ==="
TENANT_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KB_URL}/1.0/kb/tenants" \
  -u "${KB_USER}:${KB_PASS}" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: bootstrap" \
  -d '{"apiKey": "inua", "apiSecret": "inua-secret"}')
echo "tenant creation: HTTP ${TENANT_HTTP} (201=created, 409=already exists)"

echo "=== uploading catalog ==="
CATALOG_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KB_URL}/1.0/kb/catalog" \
  -u "${KB_USER}:${KB_PASS}" \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: text/xml" \
  -H "X-Killbill-CreatedBy: bootstrap" \
  --data-binary "@${SCRIPT_DIR}/../catalogs/inua/catalog-v1.xml")
echo "catalog upload: HTTP ${CATALOG_HTTP}"

echo "=== uploading overdue config ==="
OVERDUE_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KB_URL}/1.0/kb/overdue" \
  -u "${KB_USER}:${KB_PASS}" \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: text/xml" \
  -H "X-Killbill-CreatedBy: bootstrap" \
  --data-binary "@${SCRIPT_DIR}/../overdue/inua-overdue.xml")
echo "overdue upload: HTTP ${OVERDUE_HTTP}"

echo "=== setting clock to reference ==="
curl -sS -X POST "${KB_URL}/1.0/kb/test/clock?requestedDate=2026-01-01T06:00:00.000Z" \
  -u "${KB_USER}:${KB_PASS}" \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "X-Killbill-CreatedBy: bootstrap" >/dev/null
echo "clock set to 2026-01-01"

echo "=== bootstrap complete ==="
