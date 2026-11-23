#!/usr/bin/env python3
"""Minutes Desktop: writes meeting notes on this computer for the Minutes iPhone app.

The phone and this program never connect to each other. Both sign in to the same mailbox and
pass messages through one folder in it ("Minutes Desktop"): the phone leaves a job, this program
answers at once that it is here, has a model running on this computer (through Ollama) write the
notes, and leaves the result. The phone then sends the usual email.

This program reaches two things only: the mailbox (IMAP) and Ollama on this computer
(127.0.0.1). It uses the Python standard library and nothing else.

First run:   python minutes_desktop.py --setup
Every day:   python minutes_desktop.py
"""
import argparse, base64, email, email.utils, getpass, imaplib, json, os, platform, socket, sys, time
import urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = "Minutes Desktop"
DEFAULTS = {
    "address": "",
    "imap_host": "imap.gmail.com",
    "imap_port": 993,
    "imap_tls": True,
    "folder": FOLDER,
    "ollama_url": "http://127.0.0.1:11434",
    "model": "hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL",
    "writer": "Qwen 3.8 27B on the desktop",
    # How long the model stays loaded on the graphics card after a meeting.
    "keep_loaded": "10m",
    "poll_seconds": 3,
}
JOB_MAX_AGE = 600          # a job older than this was given up on by the phone
STALE_AFTER = 24 * 3600    # anything left in the folder this long is removed


def log(text):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + text
    print(line, flush=True)
    try:
        with open(os.path.join(HERE, "minutes_desktop.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ------------------------------------------------------------------ settings and the password

def load_config(path):
    config = dict(DEFAULTS)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            config.update(json.load(f))
    return config


def protect(data):
    """Encrypts bytes so that only this Windows account on this computer can read them."""
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    def blob(raw):
        buffer = ctypes.create_string_buffer(raw, len(raw))
        return Blob(len(raw), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char))), buffer

    return Blob, blob


def dpapi(data, encrypt):
    import ctypes
    Blob, blob = protect(data)
    source, keep = blob(data)
    out = Blob()
    crypt32, kernel32 = ctypes.windll.crypt32, ctypes.windll.kernel32
    call = crypt32.CryptProtectData if encrypt else crypt32.CryptUnprotectData
    if not call(ctypes.byref(source), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError("Windows could not %s the password" % ("protect" if encrypt else "read"))
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel32.LocalFree(out.pbData)


def password_path():
    return os.path.join(HERE, "password.bin")


def save_password(secret):
    if platform.system() != "Windows":
        raise SystemExit("Saving the password is supported on Windows only; set MINUTES_DESKTOP_PASSWORD instead.")
    with open(password_path(), "wb") as f:
        f.write(dpapi(secret.encode("utf-8"), True))


def load_password():
    if os.environ.get("MINUTES_DESKTOP_PASSWORD"):
        return os.environ["MINUTES_DESKTOP_PASSWORD"]
    if not os.path.exists(password_path()):
        raise SystemExit("No mailbox password saved yet. Run:  python minutes_desktop.py --setup")
    with open(password_path(), "rb") as f:
        return dpapi(f.read(), False).decode("utf-8")


def setup(config_path):
    config = load_config(config_path)
    print("Minutes Desktop setup\n")
    address = input("Gmail address Minutes sends from [%s]: " % config["address"]).strip() or config["address"]
    if "@" not in address:
        raise SystemExit("That is not an email address.")
    config["address"] = address
    print("\nThe app password for that mailbox (16 letters from myaccount.google.com/apppasswords).")
    print("It is not shown as you type, and is stored encrypted for this Windows account only.")
    secret = "".join(getpass.getpass("App password: ").split())
    if not secret:
        raise SystemExit("No password entered.")
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    save_password(secret)
    print("\nChecking the mailbox ...")
    box = Mailbox(config, secret)
    box.connect()
    box.close()
    print("Signed in, and the folder \"%s\" is ready." % config["folder"])
    print("Checking Ollama ...")
    names = ollama_models(config)
    if config["model"] not in names:
        print("Ollama is running, but this model is not downloaded:\n   ollama pull %s" % config["model"])
    else:
        print("Ollama is running and the model is there.")
    print("\nSetup is done. Start the program with:  python minutes_desktop.py")


# ------------------------------------------------------------------ the mailbox

class Mailbox:
    def __init__(self, config, password):
        self.config, self.password, self.imap = config, password, None

    def quoted(self, name=None):
        return '"%s"' % (name or self.config["folder"]).replace("\\", "\\\\").replace('"', '\\"')

    def connect(self):
        c = self.config
        if c.get("imap_tls", True):
            self.imap = imaplib.IMAP4_SSL(c["imap_host"], int(c["imap_port"]))
        else:
            self.imap = imaplib.IMAP4(c["imap_host"], int(c["imap_port"]))
        self.imap.login(c["address"], self.password)
        self.imap.create(self.quoted())                      # fails harmlessly when it exists
        kind, detail = self.imap.select(self.quoted())
        if kind != "OK":
            raise imaplib.IMAP4.error("cannot open the folder: %r" % (detail,))

    def close(self):
        try:
            self.imap.logout()
        except Exception:
            pass
        self.imap = None

    def subjects(self):
        """[(uid, subject)] for every message in the folder."""
        self.imap.noop()
        kind, data = self.imap.uid("SEARCH", None, "ALL")
        uids = data[0].split() if kind == "OK" and data and data[0] else []
        if not uids:
            return []
        kind, data = self.imap.uid("FETCH", b",".join(uids), "(UID BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
        out = []
        for part in data or []:
            if not isinstance(part, tuple):
                continue
            head = part[0].decode("ascii", "replace")
            words = head.replace("(", " ").split()
            uid = next((words[i + 1] for i, w in enumerate(words[:-1]) if w.upper() == "UID"), None)
            subject = email.message_from_bytes(part[1]).get("Subject", "")
            if uid:
                out.append((uid, " ".join(str(subject).split())))
        return out

    def body(self, uid):
        kind, data = self.imap.uid("FETCH", uid, "(BODY.PEEK[])")
        for part in data or []:
            if isinstance(part, tuple):
                return part[1]
        raise imaplib.IMAP4.error("message %s has no body" % uid)

    def leave(self, subject, payload):
        text = base64.encodebytes(json.dumps(payload).encode("utf-8")).decode("ascii")
        address = self.config["address"]
        message = (
            "From: Minutes Desktop <%s>\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s.%d@minutes.invalid>\r\n"
            "MIME-Version: 1.0\r\nContent-Type: application/json; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n%s"
            % (address, address, subject, email.utils.formatdate(), subject, int(time.time()), text.replace("\n", "\r\n"))
        )
        kind, detail = self.imap.append(self.quoted(), None, imaplib.Time2Internaldate(time.time()), message.encode("ascii"))
        if kind != "OK":
            raise imaplib.IMAP4.error("could not leave %s: %r" % (subject, detail))

    def delete(self, uid):
        try:
            self.imap.uid("COPY", uid, self.quoted("[Gmail]/Trash"))    # Gmail: so no copy stays in All Mail
        except imaplib.IMAP4.error:
            pass
        self.imap.uid("STORE", uid, "+FLAGS", "(\\Deleted)")
        self.imap.expunge()


def read_json(message):
    part = email.message_from_bytes(message)
    data = part.get_payload(decode=True)
    return json.loads(data.decode("utf-8"))


# ------------------------------------------------------------------ the model

def ollama(config, route, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(config["ollama_url"] + route, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        return json.loads(reply.read().decode("utf-8"))


def ollama_models(config):
    return [m.get("name") for m in ollama(config, "/api/tags").get("models", [])]


def generate(config, prompt, schema, words=None, max_output=None):
    """One request to the model. Returns its answer as a dict, the context size used and the speed."""
    words = int(words or len(prompt.split()))
    room = max(4096, min(16384, int(max_output or 4096)))              # tokens the answer may take
    needed = int(words * 1.5) + 2000 + room        # the transcript, the instructions, the answer
    context = next((size for size in (16384, 24576, 32768, 49152, 65536) if size >= needed), 65536)
    body = {
        "model": config["model"],
        "stream": False,
        "think": False,
        "format": schema,
        "keep_alive": config.get("keep_loaded", "10m"),
        "options": {"num_ctx": context, "temperature": 0.2, "num_predict": room},
        "messages": [{"role": "user", "content": prompt + "\nAnswer with one JSON object and nothing else."}],
    }
    reply = ollama(config, "/api/chat", body, timeout=1500)
    if reply.get("done_reason") == "length":
        raise ValueError("the notes were longer than the %d tokens allowed and were cut off" % room)
    answer = json.loads(reply["message"]["content"])
    if not isinstance(answer, dict) or not answer.get("summary"):
        raise ValueError("the model's answer had no summary")
    speed = reply.get("eval_count", 0) / (reply.get("eval_duration", 0) / 1e9) if reply.get("eval_duration") else 0
    return answer, context, speed


def write_notes(config, job):
    """The notes for a job: in one go, or part by part with a closing request when the phone
    cut a long meeting into parts. Returns what goes into the result, the context size and speed."""
    parts = job.get("parts")
    if not parts:
        notes, context, speed = generate(config, job["prompt"], job["schema"], job.get("words"), job.get("max_output"))
        return {"notes": notes}, context, speed
    written, context, speeds = [], 0, []
    for part in parts:
        notes, size, speed = generate(config, part["prompt"], job["schema"], part.get("words"), part.get("max_output"))
        written.append(notes)
        context = max(context, size)
        speeds.append(speed)
    out = {"parts": written}
    closing = job.get("closing")
    if closing:
        text = json.dumps(written, ensure_ascii=False)
        prompt = closing["prompt"].replace(closing.get("marker") or "{{PARTS}}", text)
        try:
            out["closing"], _, _ = generate(config, prompt, closing["schema"], len(text.split()), closing.get("max_output"))
        except Exception as e:                      # the parts stand without it
            log("the closing request failed, sending the parts alone: %s: %s" % (type(e).__name__, str(e)[:120]))
    return out, context, sum(speeds) / len(speeds)


# ------------------------------------------------------------------ the loop

def handle(box, config, uid, subject):
    job_id = subject[len("minutes-job-"):]
    job = read_json(box.body(uid))
    age = time.time() - float(job.get("created") or time.time())
    if age > JOB_MAX_AGE:
        log("job %s is %d minutes old; the phone has moved on, removing it" % (job_id, age // 60))
        box.delete(uid)
        return
    about = {"id": job_id, "host": socket.gethostname(), "writer": config["writer"]}
    box.leave("minutes-ack-" + job_id, about)
    if job.get("kind") == "ping":
        log("the phone asked whether the desktop is here; answered")
        box.delete(uid)
        return
    log("job %s: %s words; writing the notes" % (job_id, job.get("words", "?")))
    started = time.time()
    try:
        written, context, speed = write_notes(config, job)
        result = dict(about, seconds=round(time.time() - started, 1), **written)
        log("job %s: notes written in %.0fs (%d part(s), %.0f words a second, room for %d)"
            % (job_id, time.time() - started, len(written.get("parts") or [1]), speed, context))
    except Exception as e:                                    # the phone falls back to its own way
        result = dict(about, error=("%s: %s" % (type(e).__name__, e))[:300])
        log("job %s: failed: %s" % (job_id, result["error"]))
    # The mailbox connection may have gone quiet while the model worked.
    try:
        box.imap.noop()
    except Exception:
        box.close()
        box.connect()
    box.leave("minutes-result-" + job_id, result)
    for other, name in box.subjects():
        if name == subject:
            box.delete(other)


def sweep(box):
    """Removes what has sat in the folder for a day: answers nobody collected."""
    cutoff = imaplib.Time2Internaldate(time.time() - STALE_AFTER).split()[0].strip('"').split(" ")[0]
    kind, data = box.imap.uid("SEARCH", None, "BEFORE", cutoff)
    for uid in (data[0].split() if kind == "OK" and data and data[0] else []):
        box.delete(uid)


def run(config, password, once=False):
    log("Minutes Desktop started: mailbox %s, model %s" % (config["address"], config["model"]))
    box, last_sweep, failures = None, 0.0, 0
    while True:
        try:
            if box is None:
                box = Mailbox(config, password)
                box.connect()
                log("watching the folder \"%s\"" % config["folder"])
                failures = 0
            for uid, subject in box.subjects():
                if subject.startswith("minutes-job-"):
                    handle(box, config, uid, subject)
            if time.time() - last_sweep > 3600:
                sweep(box)
                last_sweep = time.time()
            if once:
                box.close()
                return
        except KeyboardInterrupt:
            log("stopped")
            return
        except Exception as e:
            failures += 1
            log("mailbox trouble (%s: %s); trying again in %ds" % (type(e).__name__, str(e)[:160], min(60, 5 * failures)))
            if box is not None:
                box.close()
                box = None
            if once:
                raise
            time.sleep(min(60, 5 * failures))
            continue
        time.sleep(float(config.get("poll_seconds", 3)))


def main():
    parser = argparse.ArgumentParser(description="Writes meeting notes on this computer for the Minutes iPhone app.")
    parser.add_argument("--setup", action="store_true", help="enter the mailbox address and app password")
    parser.add_argument("--config", default=os.path.join(HERE, "config.json"))
    parser.add_argument("--once", action="store_true", help="handle what is waiting and exit (for tests)")
    args = parser.parse_args()
    if args.setup:
        setup(args.config)
        return
    config = load_config(args.config)
    if "@" not in config["address"]:
        raise SystemExit("Not set up yet. Run:  python minutes_desktop.py --setup")
    run(config, load_password(), once=args.once)


if __name__ == "__main__":
    main()
