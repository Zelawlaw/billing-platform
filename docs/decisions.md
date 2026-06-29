# Decisions

## Decisions made autonomously (2026-06-29, per brief §13 recommendations)

### 1. Platform = Kill Bill tenant
**Decision:** Each platform (INUA, Afora, etc.) gets its own KB tenant.
**Reasoning:** Isolated catalogs, API credentials, and data per platform is cleaner.
INUA's own tenants (SACCO/MFI) are KB *accounts* inside the INUA tenant.

### 2. Currencies — KES now, UGX added for G7
**Decision:** Start with KES + UGX to prove multi-currency. Add TZS/RWF/NGN per market.
**UGX rates** (business decisions, not FX conversions):
  - loan r42: UGX 1,200, loan r50: UGX 1,450, loan r45: UGX 1,300
  - client r100: UGX 2,900

### 3. Loan metering — CONSUMABLE
**Decision:** `loan` and `client` are CONSUMABLE (counts per period, billed in arrear).
The rating service posts the actual count; Kill Bill sums and multiplies by rate.

### 4. Variable part timing — IN_ARREAR
**Decision:** Per-loan amount billed at period end. Setup + base in advance.
No estimation/truing-up for Phase 1.

### 5. Afora base fee — 50,000 KES
**Decision:** Placeholder; confirmed per brief spec shape (0 setup, base recurring, 45×loans).

### 6. Trial length — 30 days default
**Decision:** 30-day free trial, configurable per plan. Same for all customers.

### 7. Rating service language — Python
**Decision:** Python (matches catalog generator). FastAPI for the API surface if needed later.

### 8. Fineract access — stubbed
**Decision:** Fake Fineract (`gates/lib/fineract_stub/stub.py`) for local dev and gates.
Real Fineract integration when a running instance is available.

### 9. Payments — invoice-only locally
**Decision:** AUTO_PAY_OFF on all test accounts. Payment gateway wired later at VPS time.
