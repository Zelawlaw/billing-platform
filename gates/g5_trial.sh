#!/usr/bin/env bash
# G5: trial period generates $0 billing, billing starts at trial end.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G5: trial =="
REF="2026-01-01T06:00:00.000Z"
SETUP=123456  # unique number to distinguish from other gates

kb_clock_set "$REF"

ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G5 Trial Test","currency":"KES","billCycleDayLocal":1}')
[[ -n "$ACCT" ]] || _fail "account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null

SUB=$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"inua-annual-r42\",\"priceOverrides\":[{\"planName\":\"inua-annual-r42\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":${SETUP},\"recurringPrice\":50000,\"usagePrices\":[]}]}")
[[ -n "$SUB" ]] || _fail "subscription not created"

# During trial: no billing (only $0 trial item)
ITEMS_BEFORE=$(account_items "$ACCT")
COUNT_NONZERO=$(echo "$ITEMS_BEFORE" | awk -F'\t' '$2!="" && $3+0>0 {n++} END{print n+0}')
[[ "$COUNT_NONZERO" == "0" ]] || { echo "$ITEMS_BEFORE" >&2; _fail "non-zero items during trial"; }
_pass "no billing during trial (all items are $0)"

# Advance past trial
kb_clock_set "2026-02-05T06:00:00.000Z"

# Billing should now have FIXED and RECURRING items
assert_any_item "$ACCT" "FIXED" "$SETUP" "setup fee ${SETUP} after trial"
assert_any_item "$ACCT" "RECURRING" "" "RECURRING base after trial"

echo "${GRN}G5 PASS${NC}"
