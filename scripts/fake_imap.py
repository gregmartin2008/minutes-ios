"""A small IMAP server for tests: one account, folders kept in memory, no TLS.

It speaks just enough IMAP for the Minutes app and the desktop program to pass messages through
a folder. usage: fake_imap.py PORT [STATE.json]   (STATE.json is rewritten after every change)
"""
import json, re, socketserver, sys, threading

LOCK = threading.Lock()
FOLDERS = {"INBOX": [], "[Gmail]/Trash": []}     # name -> [{"uid", "data", "deleted"}]
NEXT = {"uid": 1}
STATE = sys.argv[2] if len(sys.argv) > 2 else None


def save():
    if STATE:
        with open(STATE, "w") as f:
            json.dump({k: [{"uid": m["uid"], "subject": subject(m["data"])} for m in v] for k, v in FOLDERS.items()}, f)


def subject(data):
    m = re.search(rb"^Subject:[ \t]*(.*?)\r?$", data, re.I | re.M)
    return m.group(1).decode() if m else ""


def unquote(s):
    s = s.strip()
    return s[1:-1].replace('\\"', '"').replace("\\\\", "\\") if s.startswith('"') else s


class Handler(socketserver.StreamRequestHandler):
    def send(self, text):
        self.wfile.write(text.encode() if isinstance(text, str) else text)
        self.wfile.flush()

    def handle(self):
        self.selected = None
        self.send("* OK fake IMAP ready\r\n")
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            parts = line.split(" ", 2)
            if len(parts) < 2:
                continue
            tag, command, rest = parts[0], parts[1].upper(), parts[2] if len(parts) > 2 else ""
            literal = None
            m = re.search(r"\{(\d+)\+?\}$", rest)
            if m:
                self.send("+ go ahead\r\n")
                literal = self.rfile.read(int(m.group(1)))
                self.rfile.readline()
                rest = rest[: m.start()].rstrip()
            with LOCK:
                try:
                    done = self.run(tag, command, rest, literal)
                except Exception as e:
                    self.send("%s BAD %s\r\n" % (tag, e))
                    done = False
                save()
            if done:
                return

    def messages(self, spec):
        box = FOLDERS[self.selected]
        wanted = set()
        for piece in spec.split(","):
            if ":" in piece:
                a, b = piece.split(":")
                hi = max([m["uid"] for m in box] or [0]) if b == "*" else int(b)
                wanted.update(range(int(a), hi + 1))
            else:
                wanted.add(int(piece))
        return [m for m in box if m["uid"] in wanted]

    def run(self, tag, command, rest, literal):
        if command == "CAPABILITY":
            self.send("* CAPABILITY IMAP4rev1\r\n%s OK done\r\n" % tag)
        elif command == "LOGIN":
            ok = '"secret"' in rest or rest.endswith(" secret")
            self.send("%s %s\r\n" % (tag, "OK signed in" if ok else "NO [AUTHENTICATIONFAILED] Invalid credentials"))
        elif command == "CREATE":
            name = unquote(rest)
            if name in FOLDERS:
                self.send("%s NO [ALREADYEXISTS] folder exists\r\n" % tag)
            else:
                FOLDERS[name] = []
                self.send("%s OK created\r\n" % tag)
        elif command == "SELECT":
            name = unquote(rest)
            if name not in FOLDERS:
                self.send("%s NO no such folder\r\n" % tag)
            else:
                self.selected = name
                self.send("* %d EXISTS\r\n* OK [UIDVALIDITY 1]\r\n%s OK [READ-WRITE] selected\r\n" % (len(FOLDERS[name]), tag))
        elif command == "NOOP":
            self.send("%s OK nothing\r\n" % tag)
        elif command == "APPEND":
            name = unquote(re.match(r'("(?:[^"\\]|\\.)*"|\S+)', rest).group(1))
            FOLDERS.setdefault(name, []).append({"uid": NEXT["uid"], "data": literal, "deleted": False})
            NEXT["uid"] += 1
            self.send("%s OK [APPENDUID 1 %d] appended\r\n" % (tag, NEXT["uid"] - 1))
        elif command == "EXPUNGE":
            FOLDERS[self.selected] = [m for m in FOLDERS[self.selected] if not m["deleted"]]
            self.send("%s OK expunged\r\n" % tag)
        elif command == "LOGOUT":
            self.send("* BYE\r\n%s OK bye\r\n" % tag)
            return True
        elif command == "UID":
            sub, _, args = rest.partition(" ")
            sub = sub.upper()
            if sub == "SEARCH":
                box = FOLDERS[self.selected]
                found = [] if "BEFORE" in args.upper() else [m["uid"] for m in box]
                self.send("* SEARCH%s\r\n%s OK searched\r\n" % ("".join(" %d" % u for u in found), tag))
            elif sub == "FETCH":
                spec, _, what = args.partition(" ")
                for i, m in enumerate(FOLDERS[self.selected], 1):
                    if m not in self.messages(spec):
                        continue
                    if "HEADER.FIELDS" in what.upper():
                        data = ("Subject: %s\r\n\r\n" % subject(m["data"])).encode()
                        self.send(b"* %d FETCH (UID %d BODY[HEADER.FIELDS (SUBJECT)] {%d}\r\n" % (i, m["uid"], len(data)) + data + b")\r\n")
                    else:
                        self.send(b"* %d FETCH (UID %d BODY[] {%d}\r\n" % (i, m["uid"], len(m["data"])) + m["data"] + b")\r\n")
                self.send("%s OK fetched\r\n" % tag)
            elif sub == "COPY":
                spec, _, name = args.partition(" ")
                for m in self.messages(spec):
                    FOLDERS.setdefault(unquote(name), []).append({"uid": NEXT["uid"], "data": m["data"], "deleted": False})
                    NEXT["uid"] += 1
                self.send("%s OK copied\r\n" % tag)
            elif sub == "STORE":
                spec = args.split(" ", 1)[0]
                for m in self.messages(spec):
                    m["deleted"] = True
                self.send("%s OK stored\r\n" % tag)
            else:
                self.send("%s BAD unknown UID command\r\n" % tag)
        else:
            self.send("%s BAD unknown command\r\n" % tag)
        return False


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
