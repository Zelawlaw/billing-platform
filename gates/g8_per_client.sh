#!/usr/bin/env bash
# G8: per-client-r100 plan bills 100 x client count monthly.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G8: per-client model =="
REF="2026-01-01T06:00:00.000Z"
CLIENTS=37
EXPECTED=$((CLIENTS * 100))

kb_clock_set "$REF"

ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G8 Per-Client","currency":"KES","billCycleDayLocal":1}')
[[ -n "$ACCT" ]] || _fail "account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null

SUB=$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"per-client-r100\",\"priceOverrides\":[{\"planName\":\"per-client-r100\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":0,\"recurringPrice\":0,\"usagePrices\":[]}]}")
[[ -n "$SUB" ]] || _fail "subscription not created"
_pass "subscription ${SUB} on per-client-r100"

# Record 37 clients
kb_clock_set "2026-01-15T06:00:00.000Z"
kb POST /1.0/kb/usages \
  "{\"subscriptionId\":\"${SUB}\",\"unitUsageRecords\":[{\"unitType\":\"client\",\"usageRecords\":[{\"recordDate\":\"2026-01-15\",\"amount\":${CLIENTS}}]}]}" >/dev/null
_pass "recorded ${CLIENTS} clients"

# Advance past first month
kb_clock_set "2026-02-05T06:00:00.000Z"
assert_any_item "$ACCT" "USAGE" "$EXPECTED" "first month: ${CLIENTS} x 100 = ${EXPECTED}"

echo "${GRN}G8 PASS${NC}"
