# Billing Platform

Central billing engine built on [Kill Bill](https://killbill.io). One stack to bill all projects — starting with INUA and Afora.

## Quick start

```bash
# Start the stack
cd docker && docker-compose up -d

# Wait for health, then bootstrap
cd docker && bash reset-and-bootstrap.sh

# Seed demo fixtures
cd bootstrap && bash seed-fixtures.sh

# Open Kaui admin UI
open http://127.0.0.1:9090  # admin/password

# Run the quality gates
make verify
```

## Structure

```
├── docker/              # Docker Compose stack (KB + Kaui + MariaDB)
├── catalogs/            # Catalog generator (prices.yml → XML)
│   ├── prices.yml       # Source of truth: plans, currencies, prices
│   ├── generate.py      # Generator script
│   └── inua/            # Generated INUA catalog XML
├── bootstrap/           # Tenant/account seeding scripts
├── gates/               # Quality gates (executable build loop)
│   ├── run-all.sh       # Runs all gates; `make verify` calls this
│   ├── lib/kb.sh        # Shared curl + assertion helpers
│   └── lib/fineract_stub/  # Fake Fineract for hermetic tests
├── rating-service/      # Sync service (Fineract → KB usage)
├── examples/            # Runnable curl flows
└── docs/decisions.md    # Architecture decisions
```

## Gates

`make verify` runs all gates from a clean DB, twice. Each gate asserts exact outcomes:

| Gate | What it proves |
|---|---|
| G0 | Stack is up, test mode on |
| G1 | Catalog validates and uploads |
| G2 | Accounts have correct, immutable currency |
| G3 | Setup fee is one-time (most important gate) |
| G4 | Usage billed in arrear at correct rate |
| G5 | Trial period = $0 billing |
| G6 | Usage idempotency behavior documented |
| G7 | Multi-currency billing (UGX account, UGX rates) |
| G8 | Per-client model (100 × clients monthly) |
| G9 | Rating service end-to-end with fake Fineract |

## Key design choices

See `docs/decisions.md`. Summary:
- **Each platform = its own KB tenant** (INUA, Afora, etc.)
- **Price overrides** for per-customer setup/base fees (same plan, different numbers)
- **Rate-variant plans** for different per-loan rates (r42, r50, r45, r100)
- **CONSUMABLE usage, billed IN_ARREAR** — loans/clients counted per period
- **KES + UGX** from day one, extensible to more currencies
