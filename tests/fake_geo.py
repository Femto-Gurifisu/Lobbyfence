"""Minimal ip-api.com compatible /batch endpoint for tests.

Like the real free endpoint: at most 15 requests per 60 s window per client
(the window starts with its first request), X-Rl (requests left) and X-Ttl
(seconds until the window resets) headers on every answer, HTTP 429 beyond
the limit, at most 100 addresses per request (422 above).
  fake_geo.py <port> <call log> [limit]
Every 429 it serves is also written to "<call log>.429". A file
"<call log>.used" holding a number counts that many requests as already made
in the current window (another device on the same internet address);
"<call log>.reset" starts a new window.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LIMIT = int(sys.argv[3]) if len(sys.argv) > 3 else 15
window = {"start": 0.0, "count": 0}

LOCATIONS = {
    "45.10.0.1": (50.1109, 8.6821, "DE"),    # Frankfurt  -> inside test circle
    "80.20.0.1": (40.7128, -74.0060, "US"),  # New York   -> outside
    "51.50.0.1": (48.8566, 2.3522, "FR"),    # Paris      -> inside (country rule test)
    "2a00:1450::1": (52.52, 13.405, "DE"),   # Berlin, IPv6
    "8.8.8.8": (37.751, -97.822, "US"),      # used by `lobbyfence apitest`
    "62.0.0.1": (41.8781, -87.6298, "US"),   # Chicago: a brand-new outside server
    "2600:1::1": (37.7749, -122.4194, "US"), # San Francisco, IPv6 -> outside
}
calls = []


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        now = time.time()
        if os.path.exists(sys.argv[2] + ".reset"):
            os.remove(sys.argv[2] + ".reset")
            window["start"], window["count"] = now, 0
        if now - window["start"] >= 60:
            window["start"], window["count"] = now, 0
        used_file = sys.argv[2] + ".used"
        if os.path.exists(used_file):
            window["count"] += int(open(used_file).read().strip() or 0)
            os.remove(used_file)
        window["count"] += 1
        left = max(0, LIMIT - window["count"])
        ttl = max(1, int(60 - (now - window["start"]) + 0.999))
        if window["count"] > LIMIT:
            with open(sys.argv[2] + ".429", "a") as f:
                f.write("%.1f\n" % now)
            self.send_response(429)
            self.send_header("X-Rl", "0")
            self.send_header("X-Ttl", str(ttl))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ips = json.loads(body)
        if len(ips) > 100:
            self.send_response(422)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        calls.append(ips)
        out = []
        for ip in ips:
            if ip in LOCATIONS:
                la, lo, cc = LOCATIONS[ip]
                out.append({"status": "success", "countryCode": cc, "lat": la, "lon": lo, "query": ip})
            else:
                out.append({"status": "fail", "message": "reserved range", "query": ip})
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("X-Rl", str(left))
        self.send_header("X-Ttl", str(ttl))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps(ips) + "\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
