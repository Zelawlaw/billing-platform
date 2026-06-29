#!/usr/bin/env python3
"""Fake Fineract returning fixed loan/client counts."""
import json, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

TENANTS = {
    "inua-tenant-a": {"loans": 42, "clients": 300},
    "inua-tenant-b": {"loans": 18, "clients": 150},
    "afora":          {"loans": 12, "clients": 80},
    "per-client-demo": {"loans": 0, "clients": 37},
}

class StubHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        params = {}
        if "?" in self.path:
            for kv in self.path.split("?")[1].split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    params[k] = v
        tenant_id = params.get("tenantId", "")
        counts = TENANTS.get(tenant_id, {"loans": 0, "clients": 0})
        if "/loans" in path:
            body = {"totalFilteredRecords": counts["loans"]}
        elif "/clients" in path:
            body = {"totalFilteredRecords": counts["clients"]}
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def log_message(self, format, *args):
        print(f"stub: {args[0]}", file=sys.stderr)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = HTTPServer(("", port), StubHandler)
    print(f"stub listening on :{port}", file=sys.stderr, flush=True)
    server.serve_forever()
