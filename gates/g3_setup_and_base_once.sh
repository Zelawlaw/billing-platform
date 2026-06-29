#!/usr/bin/env bash
# gates/g3_setup_and_base_once.sh
# PROVES: one-time setup fee charged exactly ONCE, base maintenance recurs.
# First RECURRING period may be prorated; exact-amount checks use FIXED only.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

REF="2026-01-01T06:00:00.000Z"
PLAN="inua-annual-r42"
SETUP=300000

echo "== G3: setup-once + base-recurring =="

kb_clock_set "$REF"

ACCT="$(kb_location POST /1.0/kb/accounts \
  '{"name":"Gate Tenant A","currency":"KES","billCycleDayLocal":1}')"
[[ -n "$ACCT" ]] || _fail "account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null
_pass "account ${ACCT} (KES, AUTO_PAY_OFF)"

SUB="$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"${PLAN}\",
     \"priceOverrides\":[{\"planName\":\"${PLAN}\",\"phaseType\":\"EVERGREEN\",
       \"fixedPrice\":${SETUP},\"recurringPrice\":30000,\"usagePrices\":[]}]}")"
[[ -n "$SUB" ]] || _fail "subscription not created"
_pass "subscription ${SUB} on ${PLAN}"

# Wait for trial invoice to be generated (async event processing)
sleep 5

# during trial: $0 trial invoice should exist
assert_item_type_count "$ACCT" "FIXED" 1 "during trial: 1 FIXED ($0 trial)"
assert_item_type_count "$ACCT" "RECURRING" 0 "during trial: 0 RECURRING"

# Advance past the 30-day trial -> EVERGREEN begins
kb_clock_set "2026-02-05T06:00:00.000Z"
sleep 5  # wait for billing events to process

# FIXED setup fee should appear exactly once (with the exact amount)
assert_any_item "$ACCT" "FIXED" "$SETUP" "setup fee ${SETUP} exists"

# RECURRING should have at least 1 positive item
assert_any_item "$ACCT" "RECURRING" "" "at least one positive RECURRING item"

# Count: exactly two FIXED total (trial $0 + setup $300k)
assert_item_type_count "$ACCT" "FIXED" 2 "billing start: 2 FIXED items (trial+setup)"

# Advance one annual period -> renewal
kb_clock_set "2027-02-05T06:00:00.000Z"
sleep 5  # wait for renewal billing events

# After one year: STILL only one setup fee
COUNT=$(account_items "$ACCT" | awk -F'\t' -v a="$SETUP" '$2=="FIXED" && $3==a {n++} END{print n+0}')
[[ "$COUNT" == "1" ]] || _fail "after renewal: expected 1×FIXED ${SETUP}, found ${COUNT}"
_pass "after renewal: STILL only one setup fee (one-time)"

echo "${GRN}G3 PASS${NC}"
