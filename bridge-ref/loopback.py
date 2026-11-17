#!/usr/bin/env python3
"""emacs-collab reference bridge: the "service" is a local directory.

Implements PROTOCOL.md (version 0) over stdin/stdout.  With --test it also
accepts the x-test-* messages of section 8.  Logs go to stderr only.
"""
import json
import os
import re
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ot  # noqa: E402

CAPABILITIES = ["cursors", "chat", "files"]
SELF = {"id": "loopback-self", "name": "loopback", "color": "#3366cc"}
TEST = False
ACK_DELAY = 0.3       # seconds of quiet after an Emacs edit before acking it
LOCK = threading.RLock()   # guards stdout and all bridge state


def log(*a):
    print("[loopback]", *a, file=sys.stderr, flush=True)


def send(msg):
    with LOCK:
        sys.stdout.write(json.dumps(msg, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def send_error(code, message, path=None, fatal=False):
    m = {"t": "error", "code": code, "message": message}
    if path is not None:
        m["path"] = path
    if fatal:
        m["fatal"] = True
    send(m)


class Doc:
    def __init__(self, text):
        self.text = text
        self.attached = False
        self.broken = False   # after a desync, edits are ignored until attach
        self.reset()

    def reset(self):
        self.sent = 0         # bridge edits sent
        self.seen = 0         # Emacs edits applied
        self.pending = []     # [(seq, op)] bridge edits Emacs has not confirmed
        self.acked = 0        # highest Emacs edit we have acknowledged
        self.ack_due = None   # monotonic time at which to send an ack


class Bridge:
    def __init__(self):
        self.root = None
        self.docs = {}

    # ---- filesystem -------------------------------------------------------
    def full(self, path):
        if (not isinstance(path, str) or not path or path.startswith("/")
                or "\\" in path or any(p in ("", "..") for p in path.split("/"))):
            raise ValueError("bad path %r" % (path,))
        return os.path.join(self.root, *path.split("/"))

    def read_text(self, path):
        with open(self.full(path), "rb") as f:
            data = f.read()
        return data.decode("utf-8").replace("\r\n", "\n")

    def write_atomic(self, path, text):
        full = self.full(path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(full), prefix=".loopback-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(text.encode("utf-8"))
            if os.path.exists(full):
                os.chmod(tmp, os.stat(full).st_mode & 0o7777)
            os.replace(tmp, full)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def list_files(self):
        out = []
        for d, dirs, files in os.walk(self.root):
            dirs[:] = sorted(x for x in dirs if not x.startswith("."))
            for f in sorted(files):
                if f.startswith(".loopback-"):
                    continue
                rel = os.path.relpath(os.path.join(d, f), self.root)
                out.append(rel.replace(os.sep, "/"))
        return sorted(out)

    def get_doc(self, path):
        d = self.docs.get(path)
        if d is None:
            d = Doc(self.read_text(path))
            self.docs[path] = d
        return d

    # ---- handlers ---------------------------------------------------------
    def on_hello(self, m):
        send({"t": "hello", "bridge": "loopback", "version": 0,
              "capabilities": CAPABILITIES})

    def on_open(self, m):
        dir_ = (m.get("params") or {}).get("dir")
        if not isinstance(dir_, str) or not os.path.isdir(dir_):
            send_error("open_failed", "params.dir must be an existing directory",
                       fatal=True)
            raise SystemExit(1)
        self.root = os.path.realpath(os.path.abspath(dir_))
        files = self.list_files()
        project = {"name": os.path.basename(self.root), "root": self.root,
                   "files": files}
        for cand in ("main.tex", "main.typ", "README.md"):
            if cand in files:
                project["main"] = cand
                break
        send({"t": "ready", "project": project, "self": SELF})
        send({"t": "status", "state": "connected"})

    def on_attach(self, m):
        path = m.get("path")
        try:
            d = self.get_doc(path)
        except (OSError, ValueError, UnicodeDecodeError) as e:
            send_error("attach_failed", str(e), path)
            return
        d.attached = True
        d.broken = False
        d.reset()
        send({"t": "doc", "path": path, "text": d.text, "seen": 0})

    def on_detach(self, m):
        path = m.get("path")
        d = self.docs.get(path)
        if d is None:
            return
        d.attached = False
        d.broken = False
        d.reset()
        try:
            self.write_atomic(path, d.text)
        except (OSError, ValueError) as e:
            send_error("write_failed", str(e), path)

    def desync(self, path, d, why):
        log("desync on", path, why)
        if d is not None:
            d.broken = True
        send_error("desync", why, path)

    def on_edit(self, m):
        path = m.get("path")
        d = self.docs.get(path)
        if d is None or not d.attached:
            self.desync(path, None, "edit for a document that is not attached")
            return
        if d.broken:
            log("ignoring edit on desynced", path)
            return
        try:
            seq, s, op = m["seq"], m["seen"], m["op"]
            if not (isinstance(seq, int) and isinstance(s, int)):
                raise ValueError("seq/seen must be integers")
            if seq != d.seen + 1:
                raise ValueError("sequence gap: expected %d, got %d" % (d.seen + 1, seq))
            if not (0 <= s <= d.sent):
                raise ValueError("seen %d out of range (sent %d)" % (s, d.sent))
            pending = [(q, p) for (q, p) in d.pending if q > s]
            for i, (q, p) in enumerate(pending):
                p2, op = ot.transform(p, op)          # bridge's edit first
                pending[i] = (q, p2)
            text = ot.apply(d.text, op)
        except (KeyError, ValueError, TypeError) as e:
            self.desync(path, d, str(e))
            return
        d.pending, d.text, d.seen = pending, text, seq
        d.ack_due = time.monotonic() + ACK_DELAY

    def on_ack(self, m):
        path = m.get("path")
        d = self.docs.get(path)
        if d is None or not d.attached:
            self.desync(path, None, "ack for a document that is not attached")
            return
        if d.broken:
            return
        s = m.get("seen")
        if not isinstance(s, int) or isinstance(s, bool) or not (0 <= s <= d.sent):
            self.desync(path, d, "ack.seen %r out of range (sent %d)" % (s, d.sent))
            return
        d.pending = [(q, p) for (q, p) in d.pending if q > s]

    def flush_acks(self):
        """Send the acks that are due (called from the timer thread)."""
        now = time.monotonic()
        for path, d in list(self.docs.items()):
            if d.ack_due is None or d.ack_due > now:
                continue
            d.ack_due = None
            if d.attached and not d.broken and d.seen > d.acked:
                d.acked = d.seen
                send({"t": "ack", "path": path, "seen": d.seen})

    def on_cursor(self, m):
        pass

    def on_file(self, m):
        op, path = m.get("op"), m.get("path")
        try:
            if op == "create":
                if os.path.exists(self.full(path)):
                    raise ValueError("already exists")
                text = m.get("text") or ""
                self.write_atomic(path, text)
                self.docs.pop(path, None)
                send({"t": "file_event", "op": "create", "path": path})
            elif op == "rename":
                to = m.get("to")
                src, dst = self.full(path), self.full(to)
                if os.path.exists(dst):
                    raise ValueError("target exists")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.replace(src, dst)
                if path in self.docs:
                    self.docs[to] = self.docs.pop(path)
                send({"t": "file_event", "op": "rename", "path": path, "to": to})
            elif op == "delete":
                os.unlink(self.full(path))
                self.docs.pop(path, None)
                send({"t": "file_event", "op": "delete", "path": path})
            else:
                log("unknown file op", op)
        except (OSError, ValueError) as e:
            send_error("file_failed", str(e), path if isinstance(path, str) else None)

    def on_chat(self, m):
        send({"t": "chat", "from": SELF["name"], "text": m.get("text", ""),
              "ts": int(time.time() * 1000)})

    def on_close(self, m):
        raise SystemExit(0)

    # ---- test extensions --------------------------------------------------
    def on_x_test_remote(self, m):
        path, op = m.get("path"), m.get("op")
        try:
            d = self.get_doc(path)
            text = ot.apply(d.text, op)
        except (OSError, ValueError, TypeError, UnicodeDecodeError) as e:
            send_error("test_failed", str(e), path if isinstance(path, str) else None)
            return
        d.text = text
        if d.attached:
            d.sent += 1
            d.pending.append((d.sent, op))
            d.acked = d.seen      # this remote's `seen` acknowledges them
            d.ack_due = None
            send({"t": "remote", "path": path, "seq": d.sent, "seen": d.seen,
                  "op": op})
        else:
            self.write_atomic(path, text)
            send({"t": "file_event", "op": "change", "path": path})

    def on_x_test_text(self, m):
        path = m.get("path")
        try:
            send({"t": "x-test-text", "path": path, "text": self.get_doc(path).text})
        except (OSError, ValueError, UnicodeDecodeError) as e:
            send_error("test_failed", str(e), path if isinstance(path, str) else None)

    def on_x_test_pending(self, m):
        path = m.get("path")
        d = self.docs.get(path)
        send({"t": "x-test-pending", "path": path,
              "count": len(d.pending) if d is not None else 0})

    def on_x_test_peer(self, m):
        out = {"t": "peer"}
        for k in ("id", "name", "color", "path", "pos", "mark"):
            if k in m:
                out[k] = m[k]
        send(out)

    def handle(self, m):
        t = m.get("t")
        if not isinstance(t, str) or not re.fullmatch(r"[a-z]+(-[a-z]+)*", t):
            return
        if t.startswith("x-test-") and not TEST:
            return
        fn = getattr(self, "on_" + t.replace("-", "_"), None)
        if fn is None:
            log("ignoring message type", t)
            return
        if self.root is None and t not in ("hello", "open", "close"):
            send_error("not_open", "open the project first")
            return
        fn(m)


def main():
    global TEST
    TEST = "--test" in sys.argv[1:]
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    b = Bridge()

    def ticker():
        while True:
            time.sleep(0.05)
            with LOCK:
                try:
                    b.flush_acks()
                except Exception as e:
                    log("ack error:", repr(e))

    threading.Thread(target=ticker, daemon=True).start()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            log("bad json:", line[:100])
            continue
        if not isinstance(m, dict):
            continue
        with LOCK:
            try:
                b.handle(m)
            except SystemExit:
                raise
            except Exception as e:  # keep the bridge alive on handler bugs
                log("handler error:", repr(e))
                send_error("internal", repr(e), m.get("path") if isinstance(m.get("path"), str) else None)
    log("stdin closed; exiting")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        sys.exit(e.code)
    except BrokenPipeError:
        sys.exit(0)
