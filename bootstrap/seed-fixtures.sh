#!/usr/bin/env bash
# seed-fixtures.sh — create demo accounts + subscriptions against the running stack.
# Usage: ./seed-fixtures.sh
set -euo pipefail

KB_URL="${KB_URL:-http://127.0.0.1:8081}"
KB_USER="${KB_USER:-admin}"
KB_PASS="${KB_PASS:-password}"
KB_API_KEY="${KB_API_KEY:-inua}"
KB_API_SECRET="${KB_API_SECRET:-inua-secret}"
KB_CREATED_BY="${KB_CREATED_BY:-seed}"

AUTO_PAY_OFF_TAG="00000000-0000-0000-0000-000000000001"

_hdrs=(-u "${KB_USER}:${KB_PASS}" -H "X-Killbill-ApiKey: ${KB_API_KEY}" -H "X-Killbill-ApiSecret: ${KB_API_SECRET}" -H "X-Killbill-CreatedBy: ${KB_CREATED_BY}")

kb_location() {
  local method="$1" path="$2" body="$3"
  local loc
  loc="$(curl -sS -D - -o /dev/null -X "$method" "${_hdrs[@]}" \
        -H "Content-Type: application/json" --data-binary "$body" \
        "${KB_URL}${path}" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
  echo "${loc##*/}"
}

create_account() {
  local name="$1" currency="$2" external_key="$3"
  local acct
  acct="$(kb_location POST /1.0/kb/accounts \
    "{\"name\":\"${name}\",\"currency\":\"${currency}\",\"billCycleDayLocal\":1,\"externalKey\":\"${external_key}\"}")"
  echo "$acct"
}

subscribe() {
  local acct="$1" plan="$2" fixed="$3" recurring="$4"
  local sub
  sub="$(kb_location POST "/1.0/kb/subscriptions" \
    "{\"accountId\":\"${acct}\",\"planName\":\"${plan}\",\"priceOverrides\":[{\"planName\":\"${plan}\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":${fixed},\"recurringPrice\":${recurring},\"usagePrices\":[]}]}")"
  echo "$sub"
}

echo "=== seeding fixtures ==="

# Tenant A
echo "--- INUA Tenant A ---"
ACCT_A=$(create_account "INUA Tenant A" "KES" "inua-tenant-a")
curl -sS -X POST "${KB_URL}/1.0/kb/accounts/${ACCT_A}/tags" "${_hdrs[@]}" \
  -H "Content-Type: application/json" -d "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null
SUB_A=$(subscribe "$ACCT_A" "inua-annual-r42" 300000 30000)
echo "account=$ACCT_A subscription=$SUB_A"

# Tenant B
echo "--- INUA Tenant B ---"
ACCT_B=$(create_account "INUA Tenant B" "KES" "inua-tenant-b")
curl -sS -X POST "${KB_URL}/1.0/kb/accounts/${ACCT_B}/tags" "${_hdrs[@]}" \
  -H "Content-Type: application/json" -d "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null
SUB_B=$(subscribe "$ACCT_B" "inua-annual-r50" 250000 40000)
echo "account=$ACCT_B subscription=$SUB_B"

# Per-client demo
echo "--- Per-client demo ---"
ACCT_CLIENT=$(create_account "Per-Client Demo" "KES" "per-client-demo")
curl -sS -X POST "${KB_URL}/1.0/kb/accounts/${ACCT_CLIENT}/tags" "${_hdrs[@]}" \
  -H "Content-Type: application/json" -d "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null
SUB_CLIENT=$(subscribe "$ACCT_CLIENT" "per-client-r100" 0 0)
echo "account=$ACCT_CLIENT subscription=$SUB_CLIENT"

echo "=== seed complete ==="
