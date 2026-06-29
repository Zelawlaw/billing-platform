#!/usr/bin/env bash
# gates/g0_stack.sh — Phase 0 env gate.
# PROVES: Docker stack is up, Kill Bill healthcheck returns 200, test mode is on.
set -euo pipefail
source "$(dirname "$0")/lib/kb.sh"

echo "== G0: stack health =="

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -u "${KB_USER}:${KB_PASS}" "${KB_URL}/1.0/healthcheck")
if [[ "$STATUS" != "200" ]]; then
  _fail "healthcheck returned ${STATUS}, expected 200"
fi
_pass "healthcheck 200"

CLOCK=$(kb_clock_get)
if echo "$CLOCK" | jq -e '.currentUtcTime' >/dev/null 2>&1; then
  _pass "test mode on, clock returns: $(echo "$CLOCK" | jq -r '.currentUtcTime')"
else
  _fail "test clock not accessible — is KILLBILL_SERVER_TEST_MODE=true?"
fi

echo "${GRN}G0 PASS${NC}"
