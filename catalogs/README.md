# catalogs/ — Kill Bill catalog generator

One Kill Bill catalog per platform/tenant. You **edit `prices.yml`**, run the
generator, and get valid catalog XML. Never hand-edit the XML.

```bash
pip install pyyaml
python3 generate.py prices.yml inua/catalog-v1.xml      # write
python3 generate.py prices.yml --validate-only          # check without writing
```

## Why a generator (not raw XML)

Kill Bill requires that **every price carries a value for every declared
currency**. With KES only that's trivial; the moment you add UGX/TZS/NGN it's a
sweep through every plan. The generator turns that into a small table and
**refuses to emit** an incomplete or ambiguous catalog. Proven guardrails:

- Add a currency but leave a scalar usage rate → error (a local rate is a
  business decision, not an FX conversion — give an explicit per-currency map).
- Any price missing a declared currency → error naming the currency.
- Invalid plan/product/unit name (leading digit, spaces, symbols) → error.

## The model each plan encodes

`trial? → EVERGREEN( fixed setup + recurring base + CONSUMABLE in-arrear usage )`

| Piece | Where it lives | Per-customer? |
|---|---|---|
| One-time **setup fee** | `setup_fixed` → EVERGREEN `<fixed>` (charged **once** on phase entry) | Yes → per-subscription `priceOverride` (default 0 in catalog) |
| **Base maintenance** | `base_recurring` → EVERGREEN `<recurring>` | Yes → per-subscription `priceOverride` (default 0 in catalog) |
| **Variable** rate × count | `usage[].rate` → usage tier price | Rate is in the catalog; same rate = same plan, new rate = new plan |
| **Trial** | `trial_days` → TRIAL phase, free | Per plan |

The catalog ships setup/base as **0** on purpose: the real numbers are set
per-subscription so you don't need a plan per customer. Loan/client **rates**
differ only by which `-rXX` plan the customer is on.

## How customers map onto these plans

| Customer | Plan | Overrides at subscription creation |
|---|---|---|
| INUA Tenant A | `inua-annual-r42` | `fixedPrice: 300000`, `recurringPrice: 30000` |
| INUA Tenant B | `inua-annual-r50` | `fixedPrice: 250000`, `recurringPrice: 40000` |
| Per-client model | `per-client-r100` | none (rate is in the plan) |

Example create-subscription with overrides (the EVERGREEN phase is the target):

```bash
curl -X POST 'http://127.0.0.1:8080/1.0/kb/subscriptions' \
  -u admin:password \
  -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: <secret>' \
  -H 'X-Killbill-CreatedBy: setup' -H 'Content-Type: application/json' \
  -d '{
        "accountId": "<TENANT_A_ACCOUNT_ID>",
        "planName": "inua-annual-r42",
        "priceOverrides": [
          { "planName": "inua-annual-r42", "phaseType": "EVERGREEN",
            "fixedPrice": 300000, "recurringPrice": 30000, "usagePrices": [] }
        ]
      }'
```

## Usage units (loans / clients)

Both are CONSUMABLE (count × rate, billed in arrear). The rating service records
usage per subscription:

- **loans** — post incremental loan counts through the period; CONSUMABLE sums
  them → total loans taken × rate.
- **clients** — post **one** record per period equal to the current client
  count → clients × rate. (If you instead want true high-water-mark CAPACITY
  billing, that's a different usage structure — extend `emit_usage` in
  `generate.py`; CONSUMABLE-with-one-record covers the stated requirement.)

```bash
curl -X POST 'http://127.0.0.1:8080/1.0/kb/usages' \
  -u admin:password \
  -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: <secret>' \
  -H 'X-Killbill-CreatedBy: rating' -H 'Content-Type: application/json' \
  -d '{ "subscriptionId": "<SUB_ID>",
        "unitUsageRecords": [
          { "unitType": "loan",
            "usageRecords": [ { "recordDate": "2026-03-14", "amount": 12 } ] }
        ] }'
```

## Always validate against the running tenant before trusting a catalog

The generator guarantees well-formed XML in the right element order, but the
**authoritative** check is Kill Bill's own validation against the tenant:

```bash
curl -X POST 'http://127.0.0.1:8080/1.0/kb/catalog/xml/validation' \
  -u admin:password \
  -H 'X-Killbill-ApiKey: inua' -H 'X-Killbill-ApiSecret: <secret>' \
  -H 'Content-Type: application/xml' \
  --data-binary @inua/catalog-v1.xml
```

Then upload with `POST /1.0/kb/catalog/xml` (same headers, `Content-Type: application/xml`).

## Adding things

- **New rate** (e.g. 38/loan): add a plan `inua-annual-r38` cloning an existing
  one, change the rate, regenerate. Add it to no customer until needed.
- **New currency**: add it under `currencies`, then fill its value on every
  usage `rate` (setup/base can stay scalar 0). Regenerate — errors will point at
  anything you missed.
- **New billing type** (e.g. per-branch): add a unit, a product, and a plan with
  the appropriate `usage`. Same shape.
