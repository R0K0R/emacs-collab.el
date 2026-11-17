#!/usr/bin/env python3
"""emacs-collab conformance runner.

Plays the Emacs side of PROTOCOL.md against any bridge started with --test.

  python3 conformance/run.py --bridge "python3 bridge-ref/loopback.py" \
        [--params '{"dir": "{dir}"}'] [--rounds 50] [--only NAME]

"{dir}" in --params is replaced by a fresh temporary copy of conformance/fixture.
"""
import argparse
import json
import os
import queue
import random
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "bridge-ref"))
import ot  # noqa: E402

FIXTURE = os.path.join(HERE, "fixture")
TIMEOUT = 8.0
ALPHABET = list("abcxyz \n") + ["é", "😀", "𝒳", "𝟘", "漢", "🇰"]


STATS = {"concurrent_remotes": 0}


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def rand_str(rng, n):
    return "".join(rng.choice(ALPHABET) for _ in range(n))


def rand_op(rng, doc):
    """Random edit on doc: a few retain/delete/insert runs, biased to stay small."""
    op, left = [], len(doc)
    while left > 0:
        r = rng.random()
        n = rng.randint(1, min(left, 5))
        if r < 0.45:
            op.append(n)
        elif r < 0.65:
            op.append(-n)
        else:
            op.append(rand_str(rng, rng.randint(1, 3)))
            continue
        left -= n
    if rng.random() < 0.6:
        op.append(rand_str(rng, rng.randint(1, 3)))
    return ot.normalize(op)


# ---- Emacs side of section 4 ----------------------------------------------
class EDoc:
    def __init__(self, path, text):
        self.path, self.text = path, text
        self.sent = self.seen = 0
        self.pending = []

    def local_edit(self, client, op):
        self.text = ot.apply(self.text, op)
        self.sent += 1
        self.pending.append((self.sent, op))
        client.send({"t": "edit", "path": self.path, "seq": self.sent,
                     "seen": self.seen, "op": op})

    def on_remote(self, m):
        check(m["seq"] == self.seen + 1, "remote seq gap: want %d got %s"
              % (self.seen + 1, m["seq"]))
        s, op = m["seen"], m["op"]
        check(0 <= s <= self.sent, "remote.seen %s out of range" % s)
        self.pending = [(q, p) for (q, p) in self.pending if q > s]
        if self.pending:
            STATS["concurrent_remotes"] += 1
        for i, (q, p) in enumerate(self.pending):
            op, p2 = ot.transform(op, p)      # bridge's edit first
            self.pending[i] = (q, p2)
        self.text = ot.apply(self.text, op)
        self.seen = m["seq"]


    def on_ack(self, m):
        s = m["seen"]
        check(isinstance(s, int) and 0 <= s <= self.sent, "ack.seen %s out of range" % s)
        self.pending = [(q, p) for (q, p) in self.pending if q > s]


class Client:
    def __init__(self, cmdline, params_tpl, rounds_seed=0):
        self.tmp = tempfile.mkdtemp(prefix="emacs-collab-conf-")
        self.dir = os.path.join(self.tmp, "proj")
        shutil.copytree(FIXTURE, self.dir)
        params = json.loads(params_tpl.replace("{dir}", json.dumps(self.dir)[1:-1]))
        self.params = params
        self.proc = subprocess.Popen(
            shlex.split(cmdline) + ["--test"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL if not os.environ.get("CONF_VERBOSE") else None)
        self.q = queue.Queue()
        self.docs = {}
        self.other = []     # non-remote messages seen while waiting for something else
        threading.Thread(target=self._reader, daemon=True).start()
        self.root = None
        self.files = None
        self.caps = None
        self.hello = None
        self.ready = None

    def _reader(self):
        for raw in self.proc.stdout:
            try:
                self.q.put(json.loads(raw.decode("utf-8")))
            except ValueError:
                self.q.put({"t": "x-runner-badjson", "raw": raw.decode("utf-8", "replace")})
        self.q.put(None)

    def send(self, m):
        self.proc.stdin.write((json.dumps(m, ensure_ascii=False) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def next_msg(self, timeout=TIMEOUT):
        try:
            m = self.q.get(timeout=timeout)
        except queue.Empty:
            raise Fail("timeout waiting for a bridge message")
        if m is None:
            raise Fail("bridge closed stdout")
        check(m.get("t") != "x-runner-badjson", "bridge sent a non-JSON line: %r" % m.get("raw"))
        if m.get("t") == "remote":
            d = self.docs.get(m["path"])
            check(d is not None, "remote for unattached path %s" % m["path"])
            d.on_remote(m)
        elif m.get("t") == "ack":
            d = self.docs.get(m["path"])
            check(d is not None, "ack for unattached path %s" % m["path"])
            d.on_ack(m)
        return m

    def wait(self, pred, what, timeout=TIMEOUT):
        """Read messages (applying remotes) until pred matches; return it."""
        deadline = time.time() + timeout
        while True:
            m = self.next_msg(max(0.05, deadline - time.time()))
            if pred(m):
                return m
            self.other.append(m)

    def wait_t(self, t, **kw):
        return self.wait(lambda m: m.get("t") == t and all(m.get(k) == v for k, v in kw.items()),
                         t)

    # ---- helpers
    def handshake(self):
        self.send({"t": "hello", "client": "emacs-collab-conformance", "version": 0})
        self.hello = self.wait_t("hello")
        self.caps = self.hello.get("capabilities", [])

    def open(self):
        self.send({"t": "open", "params": self.params})
        self.ready = self.wait_t("ready")
        self.root = self.ready["project"]["root"]
        self.files = self.ready["project"]["files"]

    def start(self):
        self.handshake()
        self.open()
        return self

    def attach(self, path):
        self.docs.pop(path, None)
        self.send({"t": "attach", "path": path})
        m = self.wait_t("doc", path=path)
        d = EDoc(path, m["text"])
        self.docs[path] = d
        return d, m

    def bridge_text(self, path):
        """Round trip: all earlier remotes are applied before this returns."""
        self.send({"t": "x-test-text", "path": path})
        return self.wait_t("x-test-text", path=path)["text"]

    def read_file(self, rel):
        with open(os.path.join(self.root, *rel.split("/")), "rb") as f:
            return f.read().decode("utf-8")

    def stop(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
            self.exit_code = self.proc.returncode
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.exit_code = None
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---- scenarios ------------------------------------------------------------
SCENARIOS = []


def scenario(f):
    SCENARIOS.append(f)
    return f


@scenario
def handshake(c, ctx):
    c.handshake()
    h = c.hello
    check(h.get("version") == 0, "hello.version must be 0, got %r" % h.get("version"))
    check(isinstance(h.get("bridge"), str) and h["bridge"], "hello.bridge missing")
    check(isinstance(h.get("capabilities"), list), "hello.capabilities must be a list")


@scenario
def open_ready(c, ctx):
    c.handshake()
    c.open()
    p = c.ready["project"]
    check(os.path.isabs(p["root"]), "root is not absolute: %r" % p["root"])
    check(os.path.isdir(p["root"]), "root is not a directory")
    check(isinstance(p["files"], list) and p["files"], "files empty")
    for f in p["files"]:
        check(not f.startswith("/") and ".." not in f.split("/") and "\\" not in f,
              "bad path in files: %r" % f)
    if ctx["default_params"]:
        for f in ("a.txt", "notes/b.txt", "main.tex"):
            check(f in p["files"], "missing file %s in ready.files" % f)
        check(os.path.realpath(p["root"]) == os.path.realpath(c.dir),
              "root should be the opened dir")
    for f in p["files"]:
        check(os.path.isfile(os.path.join(p["root"], *f.split("/"))),
              "listed file not in mirror: %s" % f)
    s = c.ready.get("self", {})
    check(all(k in s for k in ("id", "name", "color")), "ready.self needs id,name,color")


@scenario
def attach_doc(c, ctx):
    c.start()
    d, m = c.attach("a.txt")
    check(m["seen"] == 0, "fresh attach doc.seen must be 0")
    check(m["text"] == c.read_file("a.txt").replace("\r\n", "\n"), "doc.text != file contents")
    check("\r" not in m["text"], "text contains CR")


@scenario
def emacs_edits_only(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    rng = random.Random(1)
    for _ in range(25):
        d.local_edit(c, rand_op(rng, d.text))
    check(c.bridge_text("a.txt") == d.text, "bridge text != emacs text")
    check(not any(m.get("t") == "error" for m in c.other), "bridge reported an error")


@scenario
def remote_edits_only(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    rng = random.Random(2)
    bt = d.text
    for i in range(20):
        op = rand_op(rng, bt)
        bt = ot.apply(bt, op)
        c.send({"t": "x-test-remote", "path": "a.txt", "op": op})
    c.bridge_text("a.txt")
    check(d.text == bt, "emacs text != expected after remotes")
    check(d.seen == 20, "emacs applied %d remotes, expected 20" % d.seen)
    check(d.pending == [], "unexpected pending")


@scenario
def bridge_acks_emacs_edits(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    rng = random.Random(3)
    for _ in range(30):
        d.local_edit(c, rand_op(rng, d.text))
    check(len(d.pending) == 30, "edits should be pending before any ack")
    # a quiet period: the bridge SHOULD ack within about a second
    deadline = time.time() + 3.0
    while d.pending and time.time() < deadline:
        try:
            c.next_msg(max(0.05, deadline - time.time()))
        except Fail:
            break
    check(d.pending == [], "bridge did not ack: %d edits still pending" % len(d.pending))
    check(c.bridge_text("a.txt") == d.text, "bridge text != emacs text")


@scenario
def bridge_accepts_ack(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    rng = random.Random(4)
    bt = d.text
    for _ in range(5):
        op = rand_op(rng, bt)
        bt = ot.apply(bt, op)
        c.send({"t": "x-test-remote", "path": "a.txt", "op": op})
    c.bridge_text("a.txt")
    check(d.seen == 5 and d.text == bt, "remotes not applied")

    def count():
        c.send({"t": "x-test-pending", "path": "a.txt"})
        return c.wait_t("x-test-pending", path="a.txt")["count"]
    check(count() == 5, "bridge pending should be 5 before the ack")
    c.send({"t": "ack", "path": "a.txt", "seen": 3})
    check(count() == 2, "ack seen=3 should leave 2 pending")
    c.send({"t": "ack", "path": "a.txt", "seen": 5})
    check(count() == 0, "ack seen=5 should empty pending")
    check(not any(m.get("t") == "error" for m in c.other), "bridge reported an error")
    # sync still works afterwards
    d.local_edit(c, [len(d.text), "after ack\n"])
    check(c.bridge_text("a.txt") == d.text, "bridge text != emacs text after ack")


def concurrent_round(c, seed, nonbmp_seed_text=True):
    rng = random.Random(seed)
    path = "a.txt"
    d, _ = c.attach(path)
    for rnd in range(rng.randint(3, 8)):
        # 1. burst of Emacs edits, no reads: they stay pending
        for _ in range(rng.randint(0, 4)):
            d.local_edit(c, rand_op(rng, d.text))
        # 2. learn the bridge's current text; remotes from the previous
        #    rnd arrive here, concurrent with the edits just sent
        bt = c.bridge_text(path)
        # 3. chained remote edits on the bridge's current text, no reads
        for _ in range(rng.randint(0, 3)):
            op = rand_op(rng, bt)
            bt = ot.apply(bt, op)
            c.send({"t": "x-test-remote", "path": path, "op": op})
        # occasionally let Emacs edit with fresh state before the next round
        if rng.random() < 0.3:
            c.bridge_text(path)
    final = c.bridge_text(path)
    check(d.text == final, "diverged: emacs=%r bridge=%r" % (d.text, final))
    check(not any(m.get("t") == "error" for m in c.other), "bridge reported an error: %r" % c.other)
    c.send({"t": "detach", "path": path})
    after = c.bridge_text(path)     # ordering fence: detach is processed first
    check(after == final, "bridge text changed on detach")
    check(c.read_file(path) == final.replace("\r\n", "\n"),
          "file on disk after detach != converged text")


@scenario
def concurrent(c, ctx):
    # `c` is only used for the process-independent parts; each round gets its
    # own bridge process so a failure pinpoints the seed.
    for seed in range(ctx["rounds"]):
        cc = Client(ctx["bridge"], ctx["params"]).start()
        try:
            concurrent_round(cc, seed)
        except Fail as e:
            raise Fail("seed %d: %s" % (seed, e))
        finally:
            cc.stop()


@scenario
def concurrency_was_exercised(c, ctx):
    check(STATS["concurrent_remotes"] > 0 or ctx["only"],
          "no remote edit ever arrived while Emacs edits were pending")
    print("      (%d remote edits transformed against pending Emacs edits)"
          % STATS["concurrent_remotes"])


@scenario
def detach_writes_file(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    before = c.read_file("a.txt")
    d.local_edit(c, [len(d.text), "tail 😀\n"])
    d.local_edit(c, ["head ", len(d.text)])
    check(c.bridge_text("a.txt") == d.text, "bridge text != emacs text")
    check(c.read_file("a.txt") == before, "bridge wrote an attached file")
    c.send({"t": "detach", "path": "a.txt"})
    c.bridge_text("a.txt")
    check(c.read_file("a.txt") == d.text, "detach did not write the final text")
    check(d.text.startswith("head ") and d.text.endswith("tail 😀\n"), "sanity")
    # unattached remote edits are persisted by the bridge
    bt = c.bridge_text("a.txt")
    c.send({"t": "x-test-remote", "path": "a.txt", "op": [len(bt), "more\n"]})
    c.bridge_text("a.txt")
    check(c.read_file("a.txt") == bt + "more\n", "unattached file not persisted")
    # re-attach sees the new text
    d2, m = c.attach("a.txt")
    check(m["text"] == bt + "more\n", "re-attach text mismatch")


@scenario
def file_events(c, ctx):
    c.start()
    if "files" not in c.caps:
        print("      (bridge lacks 'files' capability; skipped)")
        return
    c.send({"t": "file", "op": "create", "path": "new/x.txt", "text": "héllo 😀\n"})
    m = c.wait_t("file_event", op="create", path="new/x.txt")
    check(c.read_file("new/x.txt") == "héllo 😀\n", "created file content wrong")
    c.send({"t": "file", "op": "rename", "path": "new/x.txt", "to": "new/y.txt"})
    m = c.wait_t("file_event", op="rename", path="new/x.txt")
    check(m.get("to") == "new/y.txt", "rename event missing 'to'")
    check(not os.path.exists(os.path.join(c.root, "new", "x.txt")), "old file still exists")
    check(c.read_file("new/y.txt") == "héllo 😀\n", "renamed content wrong")
    c.send({"t": "file", "op": "delete", "path": "new/y.txt"})
    c.wait_t("file_event", op="delete", path="new/y.txt")
    check(not os.path.exists(os.path.join(c.root, "new", "y.txt")), "deleted file still exists")


@scenario
def unknown_ignored(c, ctx):
    c.start()
    c.send({"t": "x-unknown-foo"})
    c.send({"t": "x-unknown-foo", "a": [1, 2], "b": {"c": None}})
    c.send({"t": "totally-unknown-type", "path": "a.txt"})
    c.send({"t": "attach", "path": "a.txt", "extra_field": 42, "another": {"x": 1}})
    m = c.wait_t("doc", path="a.txt")
    c.send({"t": "x-test-text", "path": "a.txt", "extra": True})
    c.wait_t("x-test-text", path="a.txt")
    check(not any(x.get("t") == "error" for x in c.other),
          "bridge answered unknown messages with errors: %r" % c.other)


@scenario
def desync_detection(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    # gap in seq
    c.send({"t": "edit", "path": "a.txt", "seq": 5, "seen": 0, "op": [len(d.text), "x"]})
    m = c.wait_t("error")
    check(m.get("code") == "desync", "expected desync, got %r" % m.get("code"))
    check(m.get("path") == "a.txt", "desync error must carry the path")
    # resynchronise via attach
    d, m = c.attach("a.txt")
    check(m["seen"] == 0, "doc.seen after resync")
    d.local_edit(c, [len(d.text), "ok\n"])
    check(c.bridge_text("a.txt") == d.text, "sync broken after resync")
    # base-length mismatch
    c.send({"t": "edit", "path": "a.txt", "seq": 2, "seen": 0, "op": [len(d.text) + 3]})
    m = c.wait_t("error")
    check(m.get("code") == "desync", "base length mismatch should give desync")
    d, m = c.attach("a.txt")
    d.local_edit(c, ["z", len(d.text)])
    check(c.bridge_text("a.txt") == d.text, "sync broken after second resync")


@scenario
def chat_cursor_peer(c, ctx):
    c.start()
    d, _ = c.attach("a.txt")
    c.send({"t": "cursor", "path": "a.txt", "pos": 2, "mark": 0})
    if "chat" in c.caps:
        c.send({"t": "chat", "text": "hi 😀"})
        m = c.wait_t("chat")
        check(m.get("text") == "hi 😀" and "from" in m and "ts" in m, "bad chat echo %r" % m)
    c.send({"t": "x-test-peer", "id": "p1", "name": "Pat", "color": "#ff0000",
            "path": "a.txt", "pos": 1})
    m = c.wait_t("peer", id="p1")
    check(m.get("name") == "Pat", "peer name")
    c.bridge_text("a.txt")


@scenario
def exits_on_eof(c, ctx):
    c.start()
    c.stop()
    check(c.exit_code is not None, "bridge did not exit after stdin EOF")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bridge", required=True, help="bridge command line (--test is appended)")
    ap.add_argument("--params", default=None,
                    help='open params as JSON; "{dir}" expands to a temp copy of conformance/fixture')
    ap.add_argument("--rounds", type=int, default=50)
    ap.add_argument("--only", default=None)
    args = ap.parse_args()
    ctx = {"only": args.only, "bridge": args.bridge, "rounds": args.rounds,
           "params": args.params or '{"dir": "{dir}"}',
           "default_params": args.params is None or "{dir}" in args.params}
    failed = 0
    for sc in SCENARIOS:
        if args.only and sc.__name__ != args.only:
            continue
        c = Client(ctx["bridge"], ctx["params"])
        try:
            sc(c, ctx)
            print("PASS %s" % sc.__name__)
        except Fail as e:
            failed += 1
            print("FAIL %s: %s" % (sc.__name__, e))
        except Exception as e:
            failed += 1
            print("FAIL %s: %s" % (sc.__name__, "".join(traceback.format_exception_only(type(e), e)).strip()))
            if os.environ.get("CONF_VERBOSE"):
                traceback.print_exc()
        finally:
            if sc.__name__ != "exits_on_eof":
                c.stop()
            else:
                shutil.rmtree(c.tmp, ignore_errors=True)
    print("%d scenario(s) failed" % failed if failed else "all scenarios passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
