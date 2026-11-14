"""Stand-in for LobbyFence's Google Form, for tests of share-servers.

Like the real one: a POST to /formResponse with the answer in entry.902986460
gets 200 and the form's confirmation message when the answer holds a servers
file, 400 when it doesn't (that page carries the confirmation message too,
inside the form's data - so a client must look at the status as well).
  fake_form.py <port> <log>
Each answer received is appended to <log> (one JSON line). While a file
"<log>.down" exists every request gets 503. "<log>.mode" can make a taken
answer come back differently, as some clients may see it:
  redirect  303 to a confirmation page (200, with the message)
  nomarker  200 without the confirmation message
  cut       200, but the connection closes before the page is complete
"""
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

FIELD = "entry.902986460"
OK = b"<html><body><div>LobbyFence received your servers. Thank you!</div></body></html>"
BAD = b'<html><body><script>var FB_PUBLIC_LOAD_DATA_ = ["LobbyFence received your servers. Thank you!"];</script>Missing answer</body></html>'


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if os.path.exists(sys.argv[2] + ".down"):
            return self.answer(503, b"down")
        form = urllib.parse.parse_qs(body, keep_blank_values=True)
        text = (form.get(FIELD) or [""])[0]
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"path": self.path, "type": self.headers.get("Content-Type", ""),
                                "fields": sorted(form), "text": text}) + "\n")
        if self.path.endswith("/formResponse") and "lobbyfence-servers 1" in text.splitlines()[:1]:
            mode = open(sys.argv[2] + ".mode").read().strip() if os.path.exists(sys.argv[2] + ".mode") else ""
            if mode == "redirect":
                self.send_response(303)
                self.send_header("Location", self.path.rsplit("/", 1)[0] + "/confirm")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if mode == "nomarker":
                return self.answer(200, b"<html><body>Thanks</body></html>")
            if mode == "cut":
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", "100000")
                self.end_headers()
                self.wfile.write(OK[:20])
                self.wfile.flush()
                self.close_connection = True
                return
            return self.answer(200, OK)
        return self.answer(400, BAD)

    def do_GET(self):
        if self.path.endswith("/confirm"):
            return self.answer(200, OK)
        return self.answer(404, b"not found")

    def answer(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
