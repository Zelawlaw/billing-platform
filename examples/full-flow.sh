#!/usr/bin/env bash
# examples/create-tenant-and-catalog.sh — runnable curl flow.
# Run against a local KB stack after `docker compose up -d`.

KB="http://127.0.0.1:8081"
AUTH="-u admin:password"

echo "=== 1. Create INUA tenant ==="
curl -sS -X POST "$KB/1.0/kb/tenants" $AUTH \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: examples" \
  -d '{"apiKey":"inua","apiSecret":"inua-secret"}' | jq .

echo "=== 2. Validate catalog ==="
curl -sS -X POST "$KB/1.0/kb/catalog/xml/validation" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/xml" \
  -H "X-Killbill-CreatedBy: examples" \
  --data-binary @../catalogs/inua/catalog-v1.xml

echo "=== 3. Upload catalog ==="
curl -sS -X POST "$KB/1.0/kb/catalog/xml" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/xml" \
  -H "X-Killbill-CreatedBy: examples" \
  --data-binary @../catalogs/inua/catalog-v1.xml

echo "=== 4. Create account (INUA Tenant A) ==="
ACCT=$(curl -sS -D - -o /dev/null -X POST "$KB/1.0/kb/accounts" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: examples" \
  -d '{"name":"INUA Tenant A","currency":"KES","billCycleDayLocal":1,"externalKey":"inua-tenant-a"}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')
ACCT_ID="${ACCT##*/}"
echo "accountId=$ACCT_ID"

echo "=== 5. Tag AUTO_PAY_OFF ==="
curl -sS -X POST "$KB/1.0/kb/accounts/$ACCT_ID/tags" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: examples" \
  -d '["00000000-0000-0000-0000-000000000001"]'

echo "=== 6. Create subscription with price overrides ==="
SUB=$(curl -sS -D - -o /dev/null -X POST "$KB/1.0/kb/subscriptions?callCompletion=true&timeoutSec=10" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: examples" \
  -d "{\"accountId\":\"$ACCT_ID\",\"planName\":\"inua-annual-r42\",\"priceOverrides\":[{\"planName\":\"inua-annual-r42\",\"phaseType\":\"EVERGREEN\",\"fixedPrice\":300000,\"recurringPrice\":30000,\"usagePrices\":[]}]}" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')
SUB_ID="${SUB##*/}"
echo "subscriptionId=$SUB_ID"

echo "=== 7. Record usage ==="
curl -sS -X POST "$KB/1.0/kb/usages" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "Content-Type: application/json" \
  -H "X-Killbill-CreatedBy: examples" \
  -d "{\"subscriptionId\":\"$SUB_ID\",\"unitUsageRecords\":[{\"unitType\":\"loan\",\"usageRecords\":[{\"recordDate\":\"2026-06-15\",\"amount\":12}]}]}"

echo "=== 8. Set clock and trigger invoice ==="
curl -sS -X POST "$KB/1.0/kb/test/clock?requestedDate=2027-02-01T06:00:00.000Z" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "X-Killbill-CreatedBy: examples" >/dev/null

echo "=== 9. Fetch invoices ==="
curl -sS "$KB/1.0/kb/accounts/$ACCT_ID/invoices?withItems=true" $AUTH \
  -H "X-Killbill-ApiKey: inua" \
  -H "X-Killbill-ApiSecret: inua-secret" \
  -H "X-Killbill-CreatedBy: examples" | jq '.[] | {invoiceDate, items: [.items[] | {type: .invoiceItemType, amount: .amount, currency: .currency}]}'

echo "=== View in Kaui: http://127.0.0.1:9090 (admin/password) ==="
