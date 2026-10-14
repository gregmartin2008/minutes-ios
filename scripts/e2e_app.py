#!/usr/bin/env python3
"""Runs the real app end to end in the iPhone simulator and checks what comes out.

The app (a debug build) is started with a recording in its Documents folder. On its own it then
downloads the speech models, separates the speakers, transcribes, and emails the result to a mail
server that this script runs on the same machine. The script then checks the email that arrived.

The simulator has no microphone and no Apple Intelligence, so recording and note writing are not
covered here; everything between them is.

usage: e2e_app.py <meeting.wav> <meeting.ref.json> <out dir>      (needs: pip install aiosmtpd)
"""
import email, json, os, re, shutil, socket, subprocess, sys, time
from email import policy
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult, LoginPassword

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_meeting import edit_distance, norm_words

DEVICE = "iPhone 17 Pro Max"
def _bundle_id():
    if os.environ.get("MINUTES_BUNDLE_ID"):
        return os.environ["MINUTES_BUNDLE_ID"]
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "bundle-id.txt")) as f:
            return f.read().strip() or "app.minutes.recorder"
    except OSError:
        return "app.minutes.recorder"

BUNDLE = _bundle_id()
APP = "build/sim/Build/Products/Debug-iphonesimulator/Minutes.app"
received = []


class Handler:
    async def handle_DATA(self, server, session, envelope):
        received.append((envelope.mail_from, list(envelope.rcpt_tos), envelope.content))
        return "250 2.0.0 OK queued"


def authenticator(server, session, envelope, mechanism, auth_data):
    ok = (isinstance(auth_data, LoginPassword)
          and auth_data.login == b"minutes-test@example.com" and auth_data.password == b"e2e-password")
    return AuthResult(success=ok) if ok else AuthResult(success=False, handled=False)


def simctl(*args, timeout=240, check=False):
    try:
        r = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"simctl {args[0]} timed out after {timeout}s", flush=True)
        if check:
            raise
        return ""
    if check and r.returncode != 0:
        sys.exit(f"simctl {' '.join(args)} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()


def main():
    wav, ref_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    # "live": feed the recording through the app as if it were being recorded, with the work
    # done as the audio arrives; otherwise the recording is imported and processed afterward.
    live = len(sys.argv) > 4 and sys.argv[4] == "live"
    results = "e2e-live" if live else "e2e"
    os.makedirs(os.path.join(out, results), exist_ok=True)
    os.makedirs(os.path.join(out, "shots"), exist_ok=True)
    started = time.time()
    stamp = lambda: f"[{time.time() - started:5.0f}s]"

    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    controller = Controller(Handler(), hostname="127.0.0.1", port=port, authenticator=authenticator,
                            auth_required=True, auth_require_tls=False)
    controller.start()
    print(stamp(), f"mail server listening on 127.0.0.1:{port}", flush=True)

    simctl("boot", DEVICE, timeout=120)
    simctl("bootstatus", DEVICE, timeout=600)
    simctl("install", DEVICE, APP, timeout=300, check=True)
    container = simctl("get_app_container", DEVICE, BUNDLE, "data", check=True)
    documents = os.path.join(container, "Documents")
    os.makedirs(documents, exist_ok=True)
    for stale in ("e2e-status.json", "e2e-transcript.txt", "e2e-diagnostics.txt"):
        if os.path.exists(os.path.join(documents, stale)):
            os.remove(os.path.join(documents, stale))
    shutil.copy(wav, os.path.join(documents, "e2e.wav"))
    simctl("ui", DEVICE, "appearance", "light")
    simctl("terminate", DEVICE, BUNDLE)
    args = ["-e2e", "e2e.wav", "-e2e-mail", f"127.0.0.1:{port}"] + (["-e2e-live"] if live else [])
    print(stamp(), "launching:", simctl("launch", DEVICE, BUNDLE, *args, check=True), flush=True)

    status, last = {}, None
    deadline = time.time() + 25 * 60
    status_path = os.path.join(documents, "e2e-status.json")
    while time.time() < deadline:
        time.sleep(2)
        try:
            status = json.load(open(status_path))
        except Exception:
            continue
        mark = (status.get("phase"), status.get("stage"))
        if mark != last:
            print(stamp(), "app:", status.get("phase"), "|", status.get("meetingStatus"), status.get("stage"), flush=True)
            last = mark
        if status.get("finished"):
            break
    time.sleep(3)   # let the screen settle on the finished meeting
    simctl("io", DEVICE, "screenshot", os.path.join(out, "shots", results + ".png"), timeout=60)
    subprocess.run(["sips", "-Z", "1434", os.path.join(out, "shots", results + ".png")], capture_output=True)
    controller.stop()

    for name in ("e2e-status.json", "e2e-transcript.txt", "e2e-diagnostics.txt"):
        if os.path.exists(os.path.join(documents, name)):
            shutil.copy(os.path.join(documents, name), os.path.join(out, results, name))
    for i, (_, _, raw) in enumerate(received):
        open(os.path.join(out, results, f"received-{i + 1}.eml"), "wb").write(raw)

    checks = []
    def check(name, ok, detail=""):
        checks.append(ok)
        print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail != "" else ""), flush=True)

    check("the app reported back before the time limit", bool(status.get("finished")), status.get("phase"))
    check("speech models downloaded inside the app", bool(status.get("modelsReady")), status.get("error") or "")
    check("the meeting finished processing", status.get("ok") is True, f"{status.get('meetingStatus')} at {status.get('stage')}: {status.get('error')}")
    check("several voices were told apart", status.get("speakers", 0) >= 4, f"{status.get('speakers')} voices")
    check("overlapping speech was detected", status.get("overlappedUtterances", 0) >= 1,
          f"{status.get('overlappedUtterances')} passages with overlap, {status.get('crosstalkUtterances')} marked as crosstalk")
    check("the app recorded the email as sent", status.get("emailed") is True)
    check("exactly one email reached the mail server", len(received) == 1, len(received))

    if received:
        mail_from, rcpts, raw = received[0]
        msg = email.message_from_bytes(raw, policy=policy.default)
        check("envelope sender and recipient", mail_from == "minutes-test@example.com" and rcpts == ["reader@example.com"], f"{mail_from} -> {rcpts}")
        check("subject", str(msg["subject"]).startswith("Meeting notes: "), msg["subject"])
        check("no parsing defects", not msg.defects and all(not p.defects for p in msg.walk()))
        html = msg.get_body(preferencelist=("html",))
        check("has an HTML body with the transcript", html is not None and "Transcript" in html.get_content())
        attachments = {a.get_filename(): a.get_content() for a in msg.iter_attachments()}
        transcript = next((v for k, v in attachments.items() if k and k.endswith("Transcript.txt")), None)
        check("transcript attached", transcript is not None, list(attachments))
        if transcript is not None:
            ref = json.load(open(ref_path))["lines"]
            ref_words = [w for line in sorted(ref, key=lambda r: r["start"]) for w in norm_words(line["text"])]
            header = re.compile(r"^.{1,60} \[\d+:\d\d(:\d\d)?\]( \(.*\))?$")
            # The attachment is a heading block, a blank line, then "Name [time]" lines each followed by speech.
            parts = transcript.replace("\r\n", "\n").split("\n\n", 1)
            body = parts[1] if len(parts) == 2 else transcript
            body_lines = [l for l in body.splitlines() if l.strip() and not header.match(l.strip()) and not l.startswith("[Recording paused")]
            hyp_words = norm_words(" ".join(body_lines))
            wer = edit_distance(ref_words, hyp_words) / max(len(ref_words), 1)
            check("emailed transcript matches what was said", wer <= 0.15, f"word error {wer * 100:.1f}% over {len(ref_words)} words")
            names = {m.group(1) for m in (re.match(r"^(Speaker \d+) \[", l.strip()) for l in transcript.splitlines()) if m}
            check("transcript names each voice", len(names) >= 4, sorted(names))
            heard = [t for t in ("Soterra", "Kestrel") if t in transcript]
            check("the vocabulary terms were written as given", len(heard) == 2, heard)

    if live:
        # The simulator on the build machine runs the speech models about twenty times slower
        # than the phone, so the allowance here is generous; the phone is held to a minute.
        check("after the recording ended, the email was sent within 90 seconds (simulator)", 0 < status.get("secondsAfterEnd", 0) <= 90,
              f"{status.get('secondsAfterEnd', 0):.1f}s from end to done")

    timings = status.get("timings") or {}
    print("\napp timings:", ", ".join(f"{k} {v:.1f}s" for k, v in sorted(timings.items())),
          f"| audio {status.get('audioSeconds', 0):.0f}s | whole run {status.get('seconds', 0):.0f}s"
          + (f" | after end {status.get('secondsAfterEnd', 0):.1f}s" if live else ""))
    if status.get("notesError"):
        print("notes:", status["notesError"])
    passed = sum(1 for c in checks if c)
    print(f"\n{passed}/{len(checks)} end-to-end checks passed")
    sys.exit(0 if passed == len(checks) else 1)


if __name__ == "__main__":
    main()
