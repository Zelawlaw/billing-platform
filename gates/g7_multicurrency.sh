#!/usr/bin/env bash
# G7: UGX account billed in UGX with UGX rates, not KES conversion.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G7: multi-currency billing =="
REF="2026-01-01T06:00:00.000Z"
SETUP_UGX=800000
BASE_UGX=85000

kb_clock_set "$REF"

# Create UGX account
ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G7 UGX Account","currency":"UGX","billCycleDayLocal":1}')
[[ -n "$ACCT" ]] || _fail "UGX account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null

ACCT_CURRENCY=$(kb GET "/1.0/kb/accounts/${ACCT}" -H "Accept: application/json" | jq -r '.currency')
[[ "$ACCT_CURRENCY" == "UGX" ]] || _fail "expected UGX, got $ACCT_CURRENCY"
_pass "UGX account created, currency = UGX"

# Subscribe with UGX overrides
SUB=$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"inua-annual-r42\",\"priceOverrides\":[{\"planName\":\"inua-annual-r42\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":${SETUP_UGX},\"recurringPrice\":${BASE_UGX},\"usagePrices\":[]}]}")
[[ -n "$SUB" ]] || _fail "subscription not created"
_pass "UGX subscription created"

# Advance past trial
kb_clock_set "2026-02-05T06:00:00.000Z"

# Verify invoice currency is UGX
ITEM_CURRENCY=$(account_items "$ACCT" | awk -F'\t' 'NR==1{print $4}')
[[ "$ITEM_CURRENCY" == "UGX" ]] || _fail "invoice currency is $ITEM_CURRENCY, expected UGX"
_pass "invoice items in UGX"

# Verify FIXED and RECURRING in UGX
assert_any_item "$ACCT" "FIXED" "$SETUP_UGX" "UGX setup: $(printf "%'d" $SETUP_UGX)"
assert_any_item "$ACCT" "RECURRING" "" "UGX base: at least one positive RECURRING"

echo "${GRN}G7 PASS${NC}"
