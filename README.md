# Billing Platform — Kill Bill for INUA & beyond

One billing engine for every project I run. Kill Bill owns customers, catalogs, invoicing, payments, dunning, and entitlements. A thin Python rating service syncs usage counts (loans, clients) from each project's source system into Kill Bill.

## Your billing models at a glance

| Customer | Setup (one-time) | Base (recurring) | Variable | Period | Currency |
|---|---|---|---|---|---|
| INUA Tenant A | 300,000 | 30,000/yr | 42 × loans | Annual | KES |
| INUA Tenant B | 250,000 | 40,000/yr | 50 × loans | Annual | KES |
| Per-client | 0 | 0 | 100 × clients | Monthly | KES |

Plus 30-day free trial on every annual plan. You can add a new customer by choosing a plan and setting their numbers — no catalog changes needed.

## Architecture (30 seconds)

```
Each platform (INUA and future projects)
  └─ is a Kill Bill "tenant"           ← own catalog, own API key/secret, isolated data

Each of INUA's SACCOs/MFIs
  └─ is a Kill Bill "account"          ← shares INUA's catalog, own prices via overrides

Each account subscribes to a "plan"    ← e.g. inua-annual-r42, per-client-r100
  └─ setup fee + base fee              ← set per-account via price overrides
  └─ variable (loans × rate)           ← rate lives in the catalog plan
```

Kill Bill runs in Docker on your machine. A tiny Python service pulls loan/client counts from Fineract and pushes them into Kill Bill as usage records. Kill Bill does the invoicing, dunning, and payment tracking.

---

## Deploying locally

### Prerequisites

- Docker (OrbStack or Docker Desktop)
- Python 3 with `pyyaml` (`pip install pyyaml` in a venv)
- `curl` and `jq`

### 1. Start the stack

```bash
cd docker
docker-compose up -d
```

This starts three containers:

| Container | Image | Port | Credentials |
|---|---|---|---|
| MariaDB | `killbill/mariadb:0.24` | 3306 | root / killbill |
| Kill Bill | `killbill/killbill:0.24.18` | 8081 | admin / password |
| Kaui (admin UI) | `killbill/kaui:latest` | 9090 | admin / password |

Wait for Kill Bill to be ready (30–60 seconds):

```bash
until curl -sS -o /dev/null -w '' -u admin:password http://127.0.0.1:8081/1.0/healthcheck; do sleep 3; done
echo "ready"
```

### 2. Create your tenant and upload the catalog

The catalog defines your billing products, plans, prices, and metered units. It lives in `catalogs/prices.yml` and is generated into XML that Kill Bill understands.

```bash
# Create the INUA tenant (this gives you an API key + secret)
curl -sS -X POST http://127.0.0.1:8081/1.0/kb/tenants \
  -u admin:password \
  -H 'Content-Type: application/json' \
  -H 'X-Killbill-CreatedBy: setup' \
  -d '{"apiKey":"inua","apiSecret":"inua-secret"}'

# Generate and upload the catalog
cd catalogs
python3 generate.py prices.yml inua/catalog-v1.xml
curl -sS -X POST http://127.0.0.1:8081/1.0/kb/catalog \
  -u admin:password \
  -H 'X-Killbill-ApiKey: inua' \
  -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'Content-Type: text/xml' \
  -H 'X-Killbill-CreatedBy: setup' \
  --data-binary @inua/catalog-v1.xml
```

Or run the bootstrap script that does all of the above:

```bash
bash docker/reset-and-bootstrap.sh
```

### 3. Onboard a customer (e.g. INUA Tenant A)

Three steps: create an account, tag it for invoice-only mode, and subscribe to a plan with their price overrides.

```bash
KB="http://127.0.0.1:8081"
AUTH="-u admin:password -H X-Killbill-ApiKey:inua -H X-Killbill-ApiSecret:inua-secret -H X-Killbill-CreatedBy:onboarding -H Content-Type:application/json"

# 1. Create account — externalKey links it to the source system
ACCT_ID=$(curl -sS -D - -o /dev/null -X POST $KB/1.0/kb/accounts $AUTH \
  -d '{"name":"INUA Tenant A","currency":"KES","billCycleDayLocal":1,"externalKey":"inua-tenant-a"}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}' | sed 's|.*/||')
echo "Account: $ACCT_ID"

# 2. Tag AUTO_PAY_OFF — invoices generate but no payment is attempted yet
curl -sS -X POST $KB/1.0/kb/accounts/$ACCT_ID/tags $AUTH \
  -d '["00000000-0000-0000-0000-000000000001"]' >/dev/null

# 3. Subscribe to inua-annual-r42 with per-customer price overrides
SUB_ID=$(curl -sS -D - -o /dev/null -X POST $KB/1.0/kb/subscriptions $AUTH \
  -d "{\"accountId\":\"$ACCT_ID\",\"planName\":\"inua-annual-r42\",\"priceOverrides\":[{\"planName\":\"inua-annual-r42\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":300000,\"recurringPrice\":30000,\"usagePrices\":[]}]}" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}' | sed 's|.*/||')
echo "Subscription: $SUB_ID"
```

The customer now has a 30-day free trial. After trial ends, billing starts:
- One-time setup: **300,000 KES**
- Annual base: **30,000 KES** (billed in advance each year)
- Per-loan: **42 KES** × number of loans taken (billed at year end)

Repeat for Tenant B or any future customer — just change the plan, amounts, and `externalKey`.

### 4. Push usage (loans taken)

The rating service does this on a schedule. Here's the raw API call it makes:

```bash
# Record 12 loans taken by Tenant A on June 15th
curl -sS -X POST $KB/1.0/kb/usages $AUTH \
  -d "{\"subscriptionId\":\"$SUB_ID\",\"unitUsageRecords\":[{\"unitType\":\"loan\",\"usageRecords\":[{\"recordDate\":\"2026-06-15\",\"amount\":12}]}]}"
```

Kill Bill sums all usage records for the period (CONSUMABLE mode) and bills `12 × 42 = 504 KES` as a USAGE item on the year-end invoice.

### 5. See what an invoice looks like

Kill Bill generates invoices automatically when billing events fire. To preview what a customer owes at any future date:

```bash
# Fetch all invoices for an account
curl -sS $KB/1.0/kb/accounts/$ACCT_ID/invoices $AUTH -H 'Accept: application/json' | jq '.[] | {date: .invoiceDate, balance: .balance}'

# Get detailed items for a specific invoice
INV_ID="<invoice-id-from-above>"
curl -sS $KB/1.0/kb/invoices/$INV_ID?withItems=true $AUTH -H 'Accept: application/json' | jq '.items[] | {type: .itemType, amount: .amount, description: .description}'
```

For Tenant A after the first year, the invoice will look like:

| Item | Type | Amount |
|---|---|---|
| Setup fee (one-time) | FIXED | 300,000 |
| Annual base maintenance | RECURRING | 30,000 |
| 42 loans × 42/loan | USAGE | 1,764 |
| **Total** | | **331,764** |

### 6. Verify with the admin UI

Open [http://127.0.0.1:9090](http://127.0.0.1:9090), log in with `admin` / `password`. You can browse accounts, subscriptions, invoices, and the catalog.

---

## Managing the catalog (adding rates, currencies, customers)

### Adding a new loan rate

Edit `catalogs/prices.yml`, clone an existing plan with the new rate, regenerate:

```bash
cd catalogs
# Edit prices.yml to add e.g. inua-annual-r38
python3 generate.py prices.yml inua/catalog-v1.xml
curl -sS -X POST http://127.0.0.1:8081/1.0/kb/catalog \
  -u admin:password \
  -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'Content-Type: text/xml' -H 'X-Killbill-CreatedBy: setup' \
  --data-binary @inua/catalog-v1.xml
```

### Adding a new currency

1. Add it to the `currencies:` list in `prices.yml`
2. Add its value to **every** `rate:` map on every plan (the generator will error until you do — it refuses to emit an incomplete catalog)
3. Regenerate and upload as above

**The rate is a business decision, not an FX conversion.** "42 KES" does not auto-convert to UGX — you decide the actual UGX rate. See `docs/decisions.md` for the rationale.

### Adding a new customer

Same 3-step process as step 3 above: create account → tag → subscribe with overrides. No catalog changes needed unless they need a genuinely new loan rate.

---

## Running the quality gates

`make verify` tears down the DB, starts fresh, and runs every gate in order, stopping at the first red. It runs twice to catch state leakage. Green means the billing engine is working correctly.

```bash
make verify
```

| Gate | What it proves |
|---|---|
| G0 | Stack is healthy, test clock is on |
| G1 | Catalog generator produces valid XML, KB accepts it |
| G2 | Account currency is set correctly and immutable |
| **G3** | **Setup fee is one-time — the most important gate** |
| G4 | Usage billed in-arrear at correct per-unit rate |
| G5 | Trial period = $0, billing starts after trial ends |
| G6 | CONSUMABLE usage is additive (rating service handles dedup) |
| G7 | UGX account billed in UGX with UGX rates |
| G8 | Per-client model: 37 clients × 100 = 3,700 |
| G9 | Rating service push → usage record created correctly |

A gate prints **expected vs actual** on failure so the fix is obvious. Never change a gate to get green — fix the system.

---

## The rating service

`rating-service/src/sync.py` is the glue between your source systems and Kill Bill.

**What it does:**
1. Lists all KB accounts that have an `externalKey` (linked to a source system)
2. For each account, finds the active subscription
3. Fetches loan/client counts from the source system (Fineract for INUA)
4. Pushes the **delta** (what changed since last run) as usage records to Kill Bill
5. Records what was pushed so re-runs are idempotent

**How to run it:**

```bash
cd rating-service
cp config/.env.example config/.env      # edit with your actual Fineract URL + creds
python3 src/sync.py
```

For now, Fineract is stubbed (`gates/lib/fineract_stub/stub.py`). Replace `FINERACT_URL` with your real Fineract instance when ready. The stub returns fixed counts for testing.

---

## Production checklist (before going live)

- [ ] **Remove test mode**: set `KILLBILL_SERVER_TEST_MODE=false` in `docker-compose.yml`
- [ ] **Change default passwords**: `killbill`, `admin/password`, `inua-secret`
- [ ] **Wire a payment gateway**: configure a KB payment plugin (replace `AUTO_PAY_OFF`)
- [ ] **Configure overdue/dunning**: set thresholds per tenant so unpaid accounts get blocked
- [ ] **Wire real Fineract**: update `rating-service/config/.env` with production URLs and credentials
- [ ] **Run rating service on a cron**: e.g. every hour or daily
- [ ] **Set up backups**: the MariaDB volume contains all billing data
- [ ] **Build the `can-proceed?` endpoint** (Phase 2): platforms call this to check if a tenant is in good standing before serving them

---

## Common tasks reference

```bash
# Regenerate catalog after editing prices.yml
cd catalogs && python3 generate.py prices.yml inua/catalog-v1.xml

# Upload the regenerated catalog
curl -sS -X POST http://127.0.0.1:8081/1.0/kb/catalog \
  -u admin:password -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'Content-Type: text/xml' -H 'X-Killbill-CreatedBy: setup' \
  --data-binary @inua/catalog-v1.xml

# See all active subscriptions for an account
curl -sS http://127.0.0.1:8081/1.0/kb/accounts/$ACCT_ID/bundles \
  -u admin:password -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'Accept: application/json' | jq '.[].subscriptions[] | {plan: .planName, state: .state, phase: .phaseType}'

# Check subscription state
curl -sS http://127.0.0.1:8081/1.0/kb/subscriptions/$SUB_ID \
  -u admin:password -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'Accept: application/json' | jq '{state, phaseType, chargedThroughDate}'

# Advance test clock (only in test mode)
curl -sS -X POST 'http://127.0.0.1:8081/1.0/kb/test/clock?requestedDate=2027-02-01T06:00:00.000Z' \
  -u admin:password -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: inua-secret' \
  -H 'X-Killbill-CreatedBy: test'

# Reset everything and start over
cd docker && docker-compose down -v && docker-compose up -d && bash reset-and-bootstrap.sh
```

---

## Further reading

- [`docs/decisions.md`](docs/decisions.md) — why each architectural choice was made
- [`examples/full-flow.sh`](examples/full-flow.sh) — every API call in order, runnable
- [`catalogs/README.md`](catalogs/README.md) — catalog model explained in detail
- [Kill Bill docs](https://docs.killbill.io) — upstream reference
