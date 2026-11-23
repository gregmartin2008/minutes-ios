#!/usr/bin/env python3
"""Runs the phone's side and the desktop program against each other, through a real (if small)
IMAP server and a stand-in for Ollama, and checks what each one saw and what is left behind.

usage: desktop_integration.py <path to Packages/MinutesCore>
"""
import json, os, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
asked = []


class Ollama(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({"models": [{"name": "test-model"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8"))
        asked.append(body)
        if "notCovered" in body["format"]["properties"]:
            closing = {"title": "Long call", "summary": "The closing summary of the long call.", "notCovered": "hold period"}
            self.reply({"message": {"content": json.dumps(closing)}, "eval_count": 50, "eval_duration": 1_000_000_000})
            return
        notes = {
            "title": "Offer call", "summary": "Greg Marsh and Dana Lee agreed terms.",
            "nextSteps": [{"owner": "Dana Lee", "action": "Send the model", "when": "Friday"}],
            "decisions": [], "openQuestions": [],
            "details": [{"topic": "Terms", "start": "0:05", "text": "They settled on 16.5 plus 8 after a short back and forth. Dana Lee said she would send the model. The price was $99 million."}],
        }
        self.reply({"message": {"content": json.dumps(notes)}, "eval_count": 100, "eval_duration": 1_000_000_000})


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    core = sys.argv[1]
    checks = []

    def check(name, ok, detail=""):
        checks.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  -> " + str(detail)[-600:]))

    work = tempfile.mkdtemp()
    state = os.path.join(work, "state.json")
    imap_port, ollama_port = free_port(), free_port()
    server = HTTPServer(("127.0.0.1", ollama_port), Ollama)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    imap = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_imap.py"), str(imap_port), state])

    config = os.path.join(work, "config.json")
    with open(config, "w") as f:
        json.dump({"address": "greg@example.com", "imap_host": "127.0.0.1", "imap_port": imap_port, "imap_tls": False,
                   "ollama_url": "http://127.0.0.1:%d" % ollama_port, "model": "test-model",
                   "writer": "Test Model on the desktop", "poll_seconds": 0.3}, f)
    time.sleep(0.5)
    desktop = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "desktop", "minutes_desktop.py"), "--config", config],
        env=dict(os.environ, MINUTES_DESKTOP_PASSWORD="secret"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(1.0)
        run = subprocess.run(
            ["swift", "test", "--filter", "DesktopNotesIntegrationTests"], cwd=core,
            env=dict(os.environ, MINUTES_IMAP_PORT=str(imap_port)), capture_output=True, text=True)
        out = run.stdout + run.stderr
        check("the phone's side passed its three tests", "Executed 3 tests, with 0 failures" in out, out[-1500:])
        time.sleep(1.0)

        texts = [a["messages"][0]["content"] for a in asked]
        part_asks = [t for t in texts if "of 3 of one meeting" in t]
        closing_asks = [a for a in asked if "notCovered" in a["format"]["properties"]]
        notes_jobs = [a for a, t in zip(asked, texts) if "of 3 of one meeting" not in t and "notCovered" not in a["format"]["properties"]]
        check("the short meeting was asked for once", len(notes_jobs) == 1, len(notes_jobs))
        check("the long meeting was asked for in three parts, in order",
              len(part_asks) == 3 and all("part %d of 3" % (i + 1) in t for i, t in enumerate(part_asks)), len(part_asks))
        check("each part carries only its own stretch of the transcript",
              len(part_asks) == 3 and "item 0 " in part_asks[0] and "item 44 " not in part_asks[0] and "item 44 " in part_asks[2] and "item 0 " not in part_asks[2])
        check("the closing request holds the parts' notes in place of the marker",
              len(closing_asks) == 1 and "{{PARTS}}" not in closing_asks[0]["messages"][0]["content"]
              and closing_asks[0]["messages"][0]["content"].count("Greg Marsh and Dana Lee agreed terms.") == 3)
        if notes_jobs:
            a = notes_jobs[0]
            prompt = a["messages"][0]["content"]
            check("the request carries the transcript, accents intact", "café prices included" in prompt and "Greg Marsh [0:05]" in prompt)
            check("the request carries the app's instructions and spellings", "You write meeting notes" in prompt and "Meridyan" in prompt)
            check("the answer format is plain JSON Schema", a["format"]["type"] == "object" and a["format"]["properties"]["details"]["type"] == "array", a["format"])
            check("the model is told to answer in the format, without thinking aloud", a["think"] is False and a["options"]["num_ctx"] >= 16384)
        left = json.load(open(state))
        check("nothing is left in the shared folder", left.get("Minutes Desktop") == [], left.get("Minutes Desktop"))
        check("nothing is left in the unanswered folder", left.get("Nobody Home") == [], left.get("Nobody Home"))
        check("what was removed went to the Trash, not to All Mail", len(left.get("[Gmail]/Trash", [])) >= 6, left.get("[Gmail]/Trash"))
        check("nothing reached the inbox", left.get("INBOX") == [])
    finally:
        desktop.terminate()
        imap.terminate()
        log = desktop.communicate(timeout=10)[0]
    check("the desktop program logged the ping and the notes", "answered" in log and "notes written in" in log, log[-800:])
    check("the desktop program's log holds no transcript text", "Thanks for joining" not in log and "secret" not in log)
    failed = [n for n, ok in checks if not ok]
    print("\n%d/%d checks passed" % (len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
