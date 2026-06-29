#!/usr/bin/env bash
# G6: CONSUMABLE usage is additive in KB. True idempotency is the rating service's job.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G6: usage idempotency (documented behavior) =="

REF="2026-01-01T06:00:00.000Z"
PLAN="inua-annual-r42"
LOAN_RATE=42

kb_clock_set "$REF"

ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G6 Idempotency","currency":"KES","billCycleDayLocal":1}')
[[ -n "$ACCT" ]] || _fail "account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null

SUB=$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"${PLAN}\",\"priceOverrides\":[{\"planName\":\"${PLAN}\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":0,\"recurringPrice\":0,\"usagePrices\":[]}]}")
[[ -n "$SUB" ]] || _fail "subscription not created"

# Advance past trial
kb_clock_set "2026-02-05T06:00:00.000Z"

# Push 5 loans twice
kb POST /1.0/kb/usages \
  "{\"subscriptionId\":\"${SUB}\",\"unitUsageRecords\":[{\"unitType\":\"loan\",\"usageRecords\":[{\"recordDate\":\"2026-02-05\",\"amount\":5}]}]}" >/dev/null
kb POST /1.0/kb/usages \
  "{\"subscriptionId\":\"${SUB}\",\"unitUsageRecords\":[{\"unitType\":\"loan\",\"usageRecords\":[{\"recordDate\":\"2026-02-05\",\"amount\":5}]}]}" >/dev/null
_pass "pushed 5 loans twice (CONSUMABLE sums to 10)"

# Advance to period end
kb_clock_set "2027-02-05T06:00:00.000Z"

# CONSUMABLE is additive: 10 loans x 42 = 420 (not 210)
EXPECTED_DOUBLE=$((10 * LOAN_RATE))
assert_any_item "$ACCT" "USAGE" "$EXPECTED_DOUBLE" "CONSUMABLE: double push = 10 x ${LOAN_RATE} = ${EXPECTED_DOUBLE}"
_pass "CONSUMABLE additive behavior confirmed — rating service handles dedup in G9"

echo "${GRN}G6 PASS${NC}"
