"""
rating-service — sync usage counts from source systems (Fineract) to Kill Bill.

Idempotent: tracks per-account what was already pushed so re-runs don't double-count.
Stateless: counts are read from the source system; KB is the source of truth for money.
"""
import os
import json
import logging
from datetime import datetime, timezone
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rating")

# --- config from env ---
KB_URL = os.environ.get("KB_URL", "http://127.0.0.1:8081")
KB_USER = os.environ.get("KB_USER", "admin")
KB_PASS = os.environ.get("KB_PASS", "password")
KB_API_KEY = os.environ.get("KB_API_KEY", "inua")
KB_API_SECRET = os.environ.get("KB_API_SECRET", "inua-secret")
FINERACT_URL = os.environ.get("FINERACT_URL", "http://127.0.0.1:8765/fineract/1.0")
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

KB_HEADERS = {
    "X-Killbill-ApiKey": KB_API_KEY,
    "X-Killbill-ApiSecret": KB_API_SECRET,
    "X-Killbill-CreatedBy": "rating-service",
    "Content-Type": "application/json",
}

# In-memory audit: what we last pushed per (account, period, unit).
# In production this would be a DB table. For now, a simple file.
AUDIT_FILE = os.environ.get("AUDIT_FILE", "/tmp/rating-service-audit.json")


def load_audit():
    try:
        with open(AUDIT_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_audit(audit):
    with open(AUDIT_FILE, "w") as f:
        json.dump(audit, f, indent=2)


def get_active_accounts():
    """List KB accounts that have an externalKey (linked to a source system)."""
    resp = requests.get(
        f"{KB_URL}/1.0/kb/accounts/pagination",
        auth=(KB_USER, KB_PASS),
        headers=KB_HEADERS,
        params={"limit": 1000},
        timeout=30,
    )
    resp.raise_for_status()
    accounts = []
    for acct in resp.json():
        ext_key = acct.get("externalKey")
        if ext_key:
            accounts.append({
                "id": acct["accountId"],
                "externalKey": ext_key,
                "currency": acct.get("currency", "KES"),
            })
    return accounts


def get_active_subscription(account_id):
    """Get the active subscription for an account."""
    resp = requests.get(
        f"{KB_URL}/1.0/kb/accounts/{account_id}/bundles",
        auth=(KB_USER, KB_PASS),
        headers=KB_HEADERS,
        timeout=30,
    )
    resp.raise_for_status()
    bundles = resp.json()
    for bundle in bundles:
        for sub in bundle.get("subscriptions", []):
            # Active subscriptions
            if sub.get("state") not in ("CANCELLED", "EXPIRED"):
                return sub["subscriptionId"]
    return None


def fetch_counts(external_key, unit_type):
    """Fetch count from the source system (Fineract stub or real)."""
    endpoint = f"/loans" if unit_type == "loan" else f"/clients"
    try:
        resp = requests.get(
            f"{FINERACT_URL}{endpoint}",
            params={"tenantId": external_key},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json().get("totalFilteredRecords", 0)
    except Exception as e:
        log.error(f"failed to fetch {unit_type} for {external_key}: {e}")
        return 0


def push_usage(subscription_id, unit_type, amount, record_date):
    """Push a usage record to Kill Bill."""
    if DRY_RUN:
        log.info(f"DRY_RUN: would push {amount} {unit_type} for sub {subscription_id}")
        return True
    body = {
        "subscriptionId": subscription_id,
        "unitUsageRecords": [{
            "unitType": unit_type,
            "usageRecords": [{"recordDate": record_date, "amount": amount}],
        }],
    }
    resp = requests.post(
        f"{KB_URL}/1.0/kb/usages",
        auth=(KB_USER, KB_PASS),
        headers=KB_HEADERS,
        json=body,
        timeout=30,
    )
    if resp.status_code in (200, 201):
        return True
    log.error(f"push failed [{resp.status_code}]: {resp.text}")
    return False


def sync():
    """Main sync loop: for each active account, fetch counts and push deltas."""
    audit = load_audit()
    accounts = get_active_accounts()
    log.info(f"found {len(accounts)} accounts with external keys")

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    for acct in accounts:
        sub_id = get_active_subscription(acct["id"])
        if not sub_id:
            log.info(f"no active subscription for {acct['externalKey']}, skipping")
            continue

        for unit in ("loan", "client"):
            count = fetch_counts(acct["externalKey"], unit)
            if count == 0:
                continue

            # Check what we last pushed for this period
            key = f"{acct['externalKey']}:{unit}:{today}"
            last_pushed = audit.get(key)

            if last_pushed is not None:
                delta = count - last_pushed
                if delta <= 0:
                    log.info(f"{acct['externalKey']}: {unit} unchanged ({count}), skip")
                    continue
                log.info(f"{acct['externalKey']}: {unit} delta {delta} (was {last_pushed}, now {count})")
            else:
                delta = count  # first time pushing = full count
                log.info(f"{acct['externalKey']}: {unit} first push, delta {delta}")

            if push_usage(sub_id, unit, delta, today):
                audit[key] = count
                log.info(f"pushed {delta} {unit} for {acct['externalKey']}")

    save_audit(audit)
    log.info("sync complete")


if __name__ == "__main__":
    sync()
