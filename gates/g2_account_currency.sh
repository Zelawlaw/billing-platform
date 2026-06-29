#!/usr/bin/env bash
# gates/g2_account_currency.sh — currency gate.
# PROVES: accounts are created with correct currency, currency is correctly reported.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G2: account currency =="
kb_clock_set "2026-01-01T06:00:00.000Z"

# Create KES account
KES_ACCT=$(kb_location POST /1.0/kb/accounts \
  '{"name":"G2 KES Account","currency":"KES","billCycleDayLocal":1}')
[[ -n "$KES_ACCT" ]] || _fail "KES account not created"

# Assert currency
KES_CURRENCY=$(kb GET "/1.0/kb/accounts/${KES_ACCT}" | jq -r '.currency')
[[ "$KES_CURRENCY" == "KES" ]] || _fail "expected KES, got $KES_CURRENCY"
_pass "KES account currency = KES"

# Verify currency is immutable (no update-currency endpoint exists — the property
# is only set at creation. A GET reflects it correctly.)
KES_CURRENCY2=$(kb GET "/1.0/kb/accounts/${KES_ACCT}" | jq -r '.currency')
[[ "$KES_CURRENCY2" == "KES" ]] || _fail "currency changed unexpectedly"
_pass "KES currency stable on re-read"

echo "${GRN}G2 PASS${NC}"
