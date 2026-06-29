#!/usr/bin/env bash
# create-tenant.sh — create a Kill Bill tenant (runs against the running stack).
# Usage: ./create-tenant.sh <apiKey> <apiSecret>
set -euo pipefail

KB_URL="${KB_URL:-http://127.0.0.1:8081}"
KB_USER="${KB_USER:-admin}"
KB_PASS="${KB_PASS:-password}"
API_KEY="${1:-inua}"
API_SECRET="${2:-inua-secret}"

echo "Creating tenant with apiKey=$API_KEY"
curl -sS -X POST "${KB_URL}/1.0/kb/tenants" \
  -u "${KB_USER}:${KB_PASS}" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: bootstrap" \
  -d "{\"apiKey\": \"${API_KEY}\", \"apiSecret\": \"${API_SECRET}\"}"
echo
