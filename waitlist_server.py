#!/usr/bin/env python3
"""QRKing waitlist: a tiny save script. Standard library only.

Takes  POST /api/waitlist  {"contact": "024 123 4567" | "me@mail.com"}
and adds one line to a CSV file. nginx sends requests here (see setup.sh).

Run it by hand to test:   python waitlist_server.py --port 8795 --file waitlist.csv
Read the list on the server:   cat /var/lib/qrking/waitlist.csv
"""
import argparse, csv, json, os, re, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Local part must start with a letter or digit so a saved row can never open as a spreadsheet formula.
EMAIL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._%+\-]{0,63}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$")
MAX_BODY = 2048
LIMIT, WINDOW = 10, 3600          # per address: 10 sign-ups an hour
HEADER = ["created_at", "kind", "contact"]

lock = threading.Lock()
hits = {}                         # ip -> [timestamps]


def clean(contact):
    """Return (kind, value) or None. Same rule as the page: a phone with 9-13 digits, or an email."""
    contact = (contact or "").strip()
    if len(contact) > 254:
        return None
    if EMAIL.match(contact):
        return "email", contact.lower()
    if re.fullmatch(r"\+?[\d\s().\-]{9,25}", contact):
        digits = re.sub(r"\D", "", contact)
        if 9 <= len(digits) <= 13:
            return "phone", ("+" if contact.startswith("+") else "") + digits
    return None


def too_many(ip):
    now = time.time()
    recent = [t for t in hits.get(ip, []) if now - t < WINDOW]
    if len(recent) >= LIMIT:
        hits[ip] = recent
        return True
    recent.append(now)
    hits[ip] = recent
    if len(hits) > 5000:          # keep memory small if someone sprays addresses
        for k in [k for k, v in hits.items() if not v or now - v[-1] >= WINDOW]:
            hits.pop(k, None)
    return False


def already_saved(path, value):
    try:
        with open(path, newline="", encoding="utf-8") as f:
            return any(len(r) == 3 and r[2] == value for r in csv.reader(f))
    except FileNotFoundError:
        return False


def save(path, kind, value):
    with lock:
        if already_saved(path, value):
            return                # joining twice is fine; keep one row
        new = not os.path.exists(path)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if new:
                w.writerow(HEADER)
            w.writerow([datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), kind, value])


class Handler(BaseHTTPRequestHandler):
    server_version = "qrking-waitlist"
    path_file = "waitlist.csv"

    def reply(self, code, body=None):
        data = json.dumps(body or {"ok": code == 200}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(405, {"error": "post only"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/waitlist":
            return self.reply(404, {"error": "not found"})
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = -1
        if not 0 < size <= MAX_BODY:
            return self.reply(413, {"error": "bad size"})
        try:
            contact = json.loads(self.rfile.read(size)).get("contact")
        except (ValueError, AttributeError):
            return self.reply(400, {"error": "bad request"})
        got = clean(contact if isinstance(contact, str) else "")
        if not got:
            return self.reply(422, {"error": "bad contact"})
        ip = self.headers.get("X-Real-IP") or self.client_address[0]
        with lock:
            blocked = too_many(ip)
        if blocked:
            return self.reply(429, {"error": "slow down"})
        try:
            save(self.path_file, *got)
        except OSError:
            return self.reply(500, {"error": "could not save"})
        self.reply(200)

    def log_message(self, fmt, *args):   # no contact details in logs
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8795)
    ap.add_argument("--file", default=os.path.join(os.environ.get("STATE_DIRECTORY", "."), "waitlist.csv"))
    a = ap.parse_args()
    Handler.path_file = a.file
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
