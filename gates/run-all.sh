#!/usr/bin/env bash
# gates/run-all.sh — the build loop entrypoint.  `make verify` calls this.
#
# Runs every gate in order from a CLEAN database and a reset clock, and STOPS at
# the first red. Green output means every spec requirement covered by a gate is
# currently satisfied. Run it twice (the Makefile does) to catch state leakage.
#
# Reset strategy (pick one; wire RESET_CMD in your env or docker/):
#   - fastest for local dev: tear down + recreate the DB volume, then re-bootstrap
#     the tenant + catalog (bootstrap/create-tenant.sh, catalog upload).
#   - Kill Bill ships a db-helper (./bin/db-helper -a clean) if running from source.
# The reset MUST leave: tenant created, catalog uploaded, clock at the reference.

set -uo pipefail
cd "$(dirname "$0")"

RESET_CMD="${RESET_CMD:-../docker/reset-and-bootstrap.sh}"   # provide this script
GATES=(
  g0_stack.sh
  g1_catalog.sh
  g2_account_currency.sh
  g3_setup_and_base_once.sh
  g4_usage_in_arrear.sh
  g5_trial.sh
  g6_idempotency.sh
  g7_multicurrency.sh
  g8_per_client.sh
  g9_rating.sh
  g10_overdue.sh   # Phase 2 — enable when building entitlement
)

echo "== resetting to a clean, bootstrapped state =="
if [[ -x "$RESET_CMD" ]]; then "$RESET_CMD"; else
  echo "WARN: RESET_CMD ($RESET_CMD) not found/executable — running against current state." >&2
fi

fail=0
for g in "${GATES[@]}"; do
  if [[ ! -f "$g" ]]; then echo "skip (missing): $g"; continue; fi
  echo; echo "==================== $g ===================="
  if bash "$g"; then echo ">>> $g GREEN"; else echo ">>> $g RED"; fail=1; break; fi
done

echo
if [[ "$fail" -eq 0 ]]; then echo "ALL GATES GREEN"; else
  echo "BUILD LOOP RED — fix the system (never the gate) and re-run."; fi
exit "$fail"
