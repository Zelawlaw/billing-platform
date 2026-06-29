#!/usr/bin/env bash
# gates/lib/kb.sh — shared Kill Bill client + assertion helpers for gates.
#
# TEMPLATE: endpoints/headers are verified against Kill Bill's API, but this is
# meant to be run against YOUR running stack and iterated there. Requires: bash,
# curl, jq. Source it from a gate:  source "$(dirname "$0")/lib/kb.sh"
#
# Config via env (override in run-all.sh or your .env):
KB_URL="${KB_URL:-http://127.0.0.1:8081}"
KB_USER="${KB_USER:-admin}"
KB_PASS="${KB_PASS:-password}"
KB_API_KEY="${KB_API_KEY:-inua}"
KB_API_SECRET="${KB_API_SECRET:-inua-secret}"
KB_CREATED_BY="${KB_CREATED_BY:-gates}"

# AUTO_PAY_OFF control tag: invoices are generated but no payment is attempted,
# so invoicing gates test billing in isolation (no gateway involved).
AUTO_PAY_OFF_TAG="00000000-0000-0000-0000-000000000001"

set -euo pipefail

_hdrs=(
  -u "${KB_USER}:${KB_PASS}"
  -H "X-Killbill-ApiKey: ${KB_API_KEY}"
  -H "X-Killbill-ApiSecret: ${KB_API_SECRET}"
  -H "X-Killbill-CreatedBy: ${KB_CREATED_BY}"
)

# kb METHOD PATH [JSON_BODY] [extra curl args...]
# Echoes the response body. Sets KB_STATUS to the HTTP code.
kb() {
  local method="$1" path="$2"; shift 2
  local body=""
  if [[ "${1:-}" == "{"* || "${1:-}" == "["* ]]; then
    body="$1"; shift
  fi
  local tmp; tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    KB_STATUS="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${_hdrs[@]}" -H "Content-Type: application/json" "$@" \
      --data-binary "$body" \
      "${KB_URL}${path}")"
  else
    KB_STATUS="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${_hdrs[@]}" "$@" \
      "${KB_URL}${path}")"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# kb_location METHOD PATH BODY -> echoes the UUID from the Location header
# (used by create endpoints that return 201 + Location).
kb_location() {
  local method="$1" path="$2" body="$3"
  local loc
  loc="$(curl -sS -D - -o /dev/null -X "$method" "${_hdrs[@]}" \
        -H "Content-Type: application/json" --data-binary "$body" \
        "${KB_URL}${path}" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
  echo "${loc##*/}"
}

# ---- test clock --------------------------------------------------------------
kb_clock_set()      { kb POST "/1.0/kb/test/clock?requestedDate=$1" >/dev/null; }   # ISO datetime
kb_clock_add_days() { kb PUT  "/1.0/kb/test/clock?days=$1"          >/dev/null; }
kb_clock_get()      { kb GET  "/1.0/kb/test/clock"; }

# ---- invoices ----------------------------------------------------------------
# all invoice items for an account as TSV lines: <invoiceDate>\t<TYPE>\t<amount>\t<currency>
account_items() {
  local acct="$1"
  # The account-level invoice list doesn't expand items even with withItems=true.
  # Fetch each invoice individually.
  local invoices
  invoices="$(kb GET "/1.0/kb/accounts/${acct}/invoices" -H "Accept: application/json")"
  echo "$invoices" | jq -r '.[].invoiceId' | while read -r inv_id; do
    kb GET "/1.0/kb/invoices/${inv_id}?withItems=true" -H "Accept: application/json" \
      | jq -r '.invoiceDate as $d | .items[]? // empty
               | [$d, .itemType, (.amount|tostring), .currency] | @tsv'
  done
}

# ---- assertions --------------------------------------------------------------
RED=$'\033[31m'; GRN=$'\033[32m'; NC=$'\033[0m'
_fail() { echo "${RED}FAIL${NC}: $*" >&2; exit 1; }
_pass() { echo "${GRN}ok${NC}:   $*"; }

# assert_item_count ACCOUNT TYPE AMOUNT EXPECTED_COUNT "label"
assert_item_count() {
  local acct="$1" type="$2" amount="$3" want="$4" label="$5"
  local got
  got="$(account_items "$acct" | awk -F'\t' -v t="$type" -v a="$amount" \
        '$2==t && $3==a {n++} END{print n+0}')"
  if [[ "$got" != "$want" ]]; then
    echo "---- invoice items for ${acct} ----" >&2
    account_items "$acct" >&2
    _fail "${label}: expected ${want}×(${type} ${amount}), found ${got}"
  fi
  _pass "${label}: ${want}×(${type} ${amount})"
}

# assert_item_type_count ACCOUNT TYPE EXPECTED_COUNT "label"
# Count items by type only (regardless of amount). Use for proration-safe assertions.
assert_item_type_count() {
  local acct="$1" type="$2" want="$3" label="$4"
  local got
  got="$(account_items "$acct" | awk -F'\t' -v t="$type" '$2==t{n++} END{print n+0}')"
  if [[ "$got" != "$want" ]]; then
    echo "---- invoice items for ${acct} ----" >&2
    account_items "$acct" >&2
    _fail "${label}: expected ${want}×${type} items, found ${got}"
  fi
  _pass "${label}: ${want}×${type} items"
}

# assert_any_item ACCOUNT TYPE AMOUNT "label"
# Assert at least one item of TYPE with exact AMOUNT exists. Pass empty AMOUNT for "any positive".
assert_any_item() {
  local acct="$1" type="$2" amount="$3" label="$4"
  local got
  if [[ -n "$amount" ]]; then
    got="$(account_items "$acct" | awk -F'\t' -v t="$type" -v a="$amount" '$2==t && $3==a {n++} END{print n+0}')"
  else
    got="$(account_items "$acct" | awk -F'\t' -v t="$type" '$2==t && $3+0>0 {n++} END{print n+0}')"
  fi
  [[ "$got" -gt 0 ]] || { account_items "$acct" >&2; _fail "${label}: no matching ${type} item found"; }
  _pass "${label}: found"
}
