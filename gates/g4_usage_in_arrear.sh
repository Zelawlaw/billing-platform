#!/usr/bin/env bash
# G4: usage billed in-arrear at period end, correct rate applied.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G4: usage in arrear =="
REF="2026-01-01T06:00:00.000Z"
LOAN_RATE=42

kb_clock_set "$REF"

ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G4 Usage Test","currency":"KES","billCycleDayLocal":1}')
[[ -n "$ACCT" ]] || _fail "account not created"
kb POST "/1.0/kb/accounts/${ACCT}/tags" "[\"${AUTO_PAY_OFF_TAG}\"]" >/dev/null

SUB=$(kb_location POST "/1.0/kb/subscriptions" \
  "{\"accountId\":\"${ACCT}\",\"planName\":\"inua-annual-r42\",\"priceOverrides\":[{\"planName\":\"inua-annual-r42\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":0,\"recurringPrice\":0,\"usagePrices\":[]}]}")
[[ -n "$SUB" ]] || _fail "subscription not created"
_pass "subscription ${SUB}"

# Advance past trial to EVERGREEN
kb_clock_set "2026-02-05T06:00:00.000Z"

# Record 12 loans
kb POST /1.0/kb/usages \
  "{\"subscriptionId\":\"${SUB}\",\"unitUsageRecords\":[{\"unitType\":\"loan\",\"usageRecords\":[{\"recordDate\":\"2026-02-05\",\"amount\":12}]}]}" >/dev/null
_pass "recorded 12 loan units"

# Verify NO usage item before period end
assert_item_type_count "$ACCT" "USAGE" 0 "no USAGE before period end (in arrear)"

# Advance to period end
kb_clock_set "2027-02-05T06:00:00.000Z"

# Usage should appear: 12 x 42 = 504
assert_any_item "$ACCT" "USAGE" "504" "usage at period end: 12 x ${LOAN_RATE} = 504"

echo "${GRN}G4 PASS${NC}"
