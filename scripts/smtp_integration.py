#!/usr/bin/env python3
"""Checks the app's mail code against a real SMTP server.

Starts a local SMTP server that requires a password, runs the Swift integration tests against it,
then parses what the server received with Python's standard email library and compares every part
with what the app intended to send.
"""
import json, os, socket, subprocess, sys, tempfile, email
from email import policy
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult, LoginPassword

received = []

class Handler:
    async def handle_DATA(self, server, session, envelope):
        received.append((envelope.mail_from, list(envelope.rcpt_tos), envelope.content))
        return "250 2.0.0 OK queued as test-123"

def authenticator(server, session, envelope, mechanism, auth_data):
    ok = (isinstance(auth_data, LoginPassword)
          and auth_data.login == b"greg@example.com" and auth_data.password == b"app pass word")
    return AuthResult(success=ok) if ok else AuthResult(success=False, handled=False)

def main():
    package = sys.argv[1]
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    controller = Controller(Handler(), hostname="127.0.0.1", port=port, authenticator=authenticator,
                            auth_required=True, auth_require_tls=False)
    controller.start()
    expect_path = os.path.join(tempfile.mkdtemp(), "expected.json")
    env = dict(os.environ, MINUTES_SMTP_PORT=str(port), MINUTES_SMTP_EXPECT=expect_path)
    try:
        run = subprocess.run(["swift", "test", "--filter", "SMTPIntegrationTests"], cwd=package, env=env,
                             capture_output=True, text=True)
    finally:
        controller.stop()
    tail = "\n".join((run.stdout + run.stderr).splitlines()[-12:])
    if run.returncode != 0:
        print(tail)
        sys.exit("FAIL: Swift integration tests failed")
    if "Executed 2 tests, with 0 failures" not in run.stdout + run.stderr:
        print(tail)
        sys.exit("FAIL: integration tests did not run (were they skipped?)")

    assert len(received) == 1, f"expected exactly one delivered message, got {len(received)}"
    mail_from, rcpts, raw = received[0]
    assert mail_from == "greg@example.com" and rcpts == ["greg@example.com"], (mail_from, rcpts)
    expected = json.load(open(expect_path, encoding="utf-8"))
    msg = email.message_from_bytes(raw, policy=policy.default)

    checks = []
    def check(name, ok, detail=""):
        checks.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  -> " + str(detail)[:300]))

    check("subject decodes to the original, accents and all", msg["subject"] == expected["subject"], msg["subject"])
    check("sender shows as Minutes", str(msg["from"]) == "Minutes <greg@example.com>", msg["from"])
    check("recipient", str(msg["to"]) == "greg@example.com", msg["to"])
    check("has Date and Message-ID", bool(msg["date"]) and str(msg["message-id"]).endswith("@example.com>"))
    check("no parsing defects", not msg.defects and all(not p.defects for p in msg.walk()),
          [p.defects for p in msg.walk() if p.defects])

    norm = lambda s: s.replace("\r\n", "\n")
    text = msg.get_body(preferencelist=("plain",))
    html = msg.get_body(preferencelist=("html",))
    check("plain-text body is intact", text is not None and norm(text.get_content()) == norm(expected["text"]))
    check("HTML body is intact", html is not None and norm(html.get_content()) == norm(expected["html"]))
    check("line starting with a dot survived the wire", ". A line that starts with a dot" in norm(text.get_content()))

    atts = list(msg.iter_attachments())
    check("two attachments", len(atts) == 2, len(atts))
    if len(atts) == 2:
        check("notes attachment name and content",
              atts[0].get_filename() == expected["notes_name"] and norm(atts[0].get_content()) == norm(expected["notes"]),
              atts[0].get_filename())
        check("transcript attachment name and content",
              atts[1].get_filename() == expected["transcript_name"]
              and norm(atts[1].get_content()) == norm(expected["transcript"]), atts[1].get_filename())
    lines = raw.split(b"\r\n")
    check("no line longer than 998 bytes (SMTP limit)", max(len(l) for l in lines) <= 998, max(len(l) for l in lines))
    check("message is 7-bit clean on the wire", all(b < 128 for b in raw))

    failed = [n for n, ok in checks if not ok]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed, message size {len(raw)} bytes")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
