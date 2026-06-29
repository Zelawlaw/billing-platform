#!/usr/bin/env python3
"""
can-proceed? — check if a tenant/account is in good billing standing.

Usage:
    python3 can_proceed.py <externalKey>
    python3 can_proceed.py --server                # start HTTP server

Endpoints (when running as server):
    GET /can-proceed/<externalKey>  → {"status": "ok" | "pay_now", ...}

Config via env (same as sync.py):
    KB_URL, KB_USER, KB_PASS, KB_API_KEY, KB_API_SECRET
"""
import os
import sys
import json
import requests

KB_URL = os.environ.get("KB_URL", "http://127.0.0.1:8081")
KB_USER = os.environ.get("KB_USER", "admin")
KB_PASS = os.environ.get("KB_PASS", "password")
KB_API_KEY = os.environ.get("KB_API_KEY", "inua")
KB_API_SECRET = os.environ.get("KB_API_SECRET", "inua-secret")

KB_HEADERS = {
    "X-Killbill-ApiKey": KB_API_KEY,
    "X-Killbill-ApiSecret": KB_API_SECRET,
    "X-Killbill-CreatedBy": "can-proceed",
    "Accept": "application/json",
}

AUTH = (KB_USER, KB_PASS)


def find_account_by_external_key(external_key):
    """Resolve externalKey to KB account ID."""
    url = f"{KB_URL}/1.0/kb/accounts?externalKey={external_key}"
    resp = requests.get(url, auth=AUTH, headers=KB_HEADERS, timeout=10)
    if resp.status_code in (404, 400):
        return None
    resp.raise_for_status()
    try:
        data = resp.json()
        # KB returns a single object for exact externalKey match, not a list
        if isinstance(data, dict) and "accountId" in data:
            return data["accountId"]
        if isinstance(data, list) and len(data) > 0:
            return data[0]["accountId"]
    except (ValueError, KeyError, TypeError):
        pass
    return None


def get_account_overdue(account_id):
    """Get account overdue state."""
    url = f"{KB_URL}/1.0/kb/accounts/{account_id}/overdue"
    resp = requests.get(url, auth=AUTH, headers=KB_HEADERS, timeout=10)
    resp.raise_for_status()
    return resp.json()


def get_account_balance(account_id):
    """Get account balance and CBA."""
    url = f"{KB_URL}/1.0/kb/accounts/{account_id}?accountWithBalanceAndCBA=true"
    resp = requests.get(url, auth=AUTH, headers=KB_HEADERS, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    return {
        "balance": float(data.get("accountBalance", 0) or 0),
        "cba": float(data.get("accountCBA", 0) or 0),
    }


def check_standing(external_key):
    """
    Check if a tenant/account is in good billing standing.

    Returns dict:
        {"status": "ok"}
        {"status": "pay_now", "amount_due": ..., "message": "..."}
        {"status": "unknown", "reason": "..."}
    """
    account_id = find_account_by_external_key(external_key)
    if not account_id:
        return {"status": "unknown", "reason": f"no account found for externalKey '{external_key}'"}

    try:
        overdue = get_account_overdue(account_id)
        balance_info = get_account_balance(account_id)
    except Exception as e:
        return {"status": "unknown", "reason": f"KB error: {e}"}

    is_clear = overdue.get("isClearState", True)
    is_blocked = overdue.get("isDisableEntitlementAndChangesBlocked", False)
    overdue_name = overdue.get("name", "Clear")
    message = overdue.get("externalMessage", "")
    balance = balance_info["balance"]
    cba = balance_info["cba"]
    net_due = max(0, balance - cba)

    if is_clear:
        return {
            "status": "ok",
            "overdue_state": overdue_name,
            "balance": balance,
            "cba": cba,
        }
    elif is_blocked:
        return {
            "status": "pay_now",
            "overdue_state": overdue_name,
            "message": message,
            "amount_due": net_due,
            "balance": balance,
            "cba": cba,
        }
    else:
        # Warning state — not blocked yet, but notify
        return {
            "status": "warning",
            "overdue_state": overdue_name,
            "message": message,
            "amount_due": net_due,
            "balance": balance,
            "cba": cba,
        }


def serve():
    """Run as a minimal HTTP server for platform integration."""
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class CanProceedHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/can-proceed/"):
                external_key = self.path.split("/can-proceed/", 1)[1].split("?")[0]
                result = check_standing(external_key)
                self.send_response(200 if result["status"] != "unknown" else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
            elif self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            print(f"can-proceed: {args[0]}", file=sys.stderr)

    port = int(os.environ.get("PORT", 8000))
    server = HTTPServer(("", port), CanProceedHandler)
    print(f"can-proceed listening on :{port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--server":
        serve()
    elif len(sys.argv) > 1:
        result = check_standing(sys.argv[1])
        print(json.dumps(result, indent=2))
    else:
        print(__doc__)
        sys.exit(1)
