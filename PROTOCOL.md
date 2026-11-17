# emacs-collab protocol, version 0

emacs-collab is the only protocol Emacs speaks for real-time collaborative
editing. Each collaboration service (a Yjs server, Overleaf, TeXlyre, …) has a
**bridge**: a local program that Emacs starts as a subprocess, speaking this
protocol on stdin/stdout and the service's own protocol on the network.

This document is the contract. A bridge may be written in any language. The
conformance suite (`conformance/`) checks a bridge against it, and
`bridge-ref/loopback.py` is a minimal reference implementation.

## 1. Transport

- Emacs starts the bridge (`argv` comes from the workspace config). It talks
  over the bridge's **stdin and stdout**. **stderr** is free-form logging, which
  Emacs shows in a log buffer and never parses.
- Every message is one JSON object, UTF-8, on one line, ending in `\n`. JSON
  string escaping keeps a message's newlines inside strings.
- Each message has a `"t"` field naming its type. Unknown types must be
  ignored by both sides. Unknown fields must be ignored too.
- Message types starting with `x-` are extensions (section 8).
- The bridge exits when stdin is closed.

## 2. Positions and text

- A document is a sequence of **Unicode scalar values** (code points). This is
  what an Emacs buffer holds; one character is one position.
- Every position and length on the wire counts code points, 0-based. Whatever
  the service uses (UTF-16 units for Overleaf and Yjs, UTF-8 bytes elsewhere),
  the bridge converts.
- Line endings are `\n`. The bridge normalises `\r\n` from services.
- Paths are project-relative, use `/` as the separator, and never begin with `/`
  or contain `..`.

## 3. Edits: text operations

An edit is an **operation** over the whole document, in the ot.js
`TextOperation` form. It is a JSON array of components:

- a positive integer `n`: **retain** `n` characters;
- a string `s`: **insert** `s`;
- a negative integer `-n`: **delete** `n` characters.

The components' retains and deletes must cover the document exactly: their
total is the document's length before the edit (its *base length*). Two
adjacent components never have the same kind, and none is `0` or `""`. Where an
insert and a delete are adjacent, the **insert comes first** (canonical form, as
in ot.js). Example: on `"hello"`, `[1, "a", -2, 2]` keeps `h`, inserts `a`,
deletes `el` and keeps `lo`, giving `"halo"`.

Both sides implement:

- `apply(doc, op)`;
- `compose(a, b)` (optional). **Never compose pending edits** for the sync in
  section 4. Each sent edit stays a separate pending entry: ot.js `transform` is
  not associative with `compose` when inserts tie, so composing could resolve a
  tie differently on the two sides.
- `transform(a, b)`, which returns `(a', b')` such that
  `apply(apply(d, a), b') == apply(apply(d, b), a')`. **Ties:** when `a` and `b`
  insert at the same position, `a`'s insert comes first.

The reference implementations are `bridge-ref/ot.py` and `emacs-collab-ot.el`.

## 4. Two-party synchronisation

Emacs and the bridge are the only two parties on this connection; the bridge
alone deals with the service's other clients. Each document (`path`) has
independent state on each side:

- `sent`: how many edits this side has sent for the document;
- `seen`: how many of the other side's edits it has applied;
- `pending`: its own sent edits the other side hasn't yet confirmed, in order,
  each with its sequence number.

**Sending an edit** made locally: increment `sent`, then send
`{"t":"edit","path":P,"seq":sent,"seen":seen,"op":OP}`, and append `(seq, OP)`
to `pending`. The bridge sends `"t":"remote"` messages, with the same fields,
for edits that came from the service.

**Receiving** `{seq, seen: s, op}` from the other side:

1. Drop every `pending` entry whose sequence number is `<= s`. The other side
   had already applied those when it made this edit.
2. For each remaining `pending` entry `p`, in order:
   `(op, p.op) = transform(op, p.op)` with the **bridge's edit as the first
   argument**, so that ties resolve the same way on both sides. On the Emacs
   side, the incoming `op` is the bridge's edit; on the bridge side, `p.op` is
   the bridge's own, so there it is `(p.op, op) = transform(p.op, op)`.
3. Apply `op` locally and set `seen = seq`.

`seq` values from one side are consecutive (1, 2, 3, …) per document and arrive
in order, since stdio is an ordered stream. A gap or a base-length mismatch is a
protocol error:
- the receiver answers `error {code:"desync", path}`;
- the bridge then ignores that document's edits until the next `attach`, so
  edits already in flight don't cause a loop of errors;
- **Emacs resynchronises** by sending `attach` for the path. Emacs does the
  same when it detects a desync itself.

## 5. Messages

### Emacs → bridge

| Message | Meaning |
|---|---|
| `hello {client, version:0}` | First message. |
| `open {params, credentials?}` | Open a project. `params` is bridge-specific (server URL, project id, room, …). `credentials` comes from Emacs's auth-source; the bridge must not read secrets from disk on its own. |
| `attach {path}` | Emacs has opened `path` and wants to edit it. This (re)starts that document's sync state. |
| `detach {path}` | Emacs closed the buffer. |
| `edit {path, seq, seen, op}` | A local edit (section 4). |
| `cursor {path, pos, mark?}` | Emacs's point (and mark, if the region is active), sent debounced. |
| `file {op:"create"\|"rename"\|"delete", path, to?, text?}` | Change the file tree. |
| `chat {text}` | A chat message, when the bridge has the `chat` capability. |
| `close {}` | Leave the project; the bridge should then exit. |

### Bridge → Emacs

| Message | Meaning |
|---|---|
| `hello {bridge, version:0, capabilities:[…]}` | Reply to `hello`. Capabilities: `"cursors"`, `"chat"`, `"files"` (tree edits), `"preview"`, `"binary"` (mirrors binary files). |
| `ready {project:{name, root, main?, files:[…]}, self:{id, name, color}}` | The project is open. `root` is an absolute local directory: the **mirror**, holding every file of the project (section 6). `files` lists the project-relative paths. |
| `doc {path, text, seen}` | Reply to `attach`: the full current text. In v0 `seen` is always `0`. Both sides reset this document's state (`sent` = 0, `seen` = 0, `pending` empty): Emacs after replacing its buffer's text when it differs, the bridge when it sends `doc`. |
| `remote {path, seq, seen, op}` | An edit from the service (section 4). |
| `peer {id, name, color, path?, pos?, mark?}` | Another participant appeared, or moved. |
| `peer_left {id}` | That participant left. |
| `file_event {op:"create"\|"rename"\|"delete"\|"change", path, to?}` | The tree changed on the service. For unattached files the bridge has already updated the mirror. |
| `chat {from, from_id?, text, ts}` | A chat message. `from` is the sender's display name (a string), `ts` Unix seconds. |
| `status {state:"connecting"\|"connected"\|"offline"\|"resyncing", detail?}` | Connection state, for the mode line. |
| `preview {url}` | A URL showing the rendered project, when the bridge has the `preview` capability. |
| `need_auth {fields:[…], reason?}` | Credentials are missing or were rejected. Emacs asks auth-source or the user and sends `open` again. |
| `error {code, message, path?, fatal?}` | A failure. When `fatal` is true, the bridge exits after sending it. |

## 6. The mirror

- `ready.root` is a local directory with every file of the project. Emacs
  visits files there, so ordinary tools (compilers, LSP, grep) see real files.
- The bridge keeps **unattached** files up to date on disk, writing atomically
  (temporary file, then rename).
- For an **attached** file the buffer is authoritative. The bridge does not
  write it while it is attached; Emacs saves the buffer as usual.
- Binary files, such as images, are written by the bridge only if it has the
  `binary` capability.

## 7. Errors and reconnection

- When the service connection drops, the bridge reports `status
  {state:"offline"}`. Emacs keeps editing; its edits are sent as usual and the
  bridge queues them.
- On reconnect, the bridge brings each attached document up to date with the
  service and reports `resyncing`, then `connected`. It sends any missed
  service edits to Emacs as ordinary `remote` messages.
- If it cannot reconcile a document, it sends that document's `doc` again,
  after sending `error {code:"resync", path}`.
- Emacs must never lose an edit without telling the user.

## 8. Extensions

Types starting with `x-` are reserved for extensions. Unknown ones are ignored.

`x-test-*` messages are reserved for conformance testing; a bridge accepts them
only when started with `--test`:

- `x-test-remote {path, op}` (Emacs → bridge): make `op` arrive as if from the
  service, based on the bridge's current text of `path`.
  - If `path` is attached, the bridge forwards it to Emacs as an ordinary `remote`.
  - Otherwise it updates the mirror file and sends `file_event {op:"change"}`.
- `x-test-text {path}` (Emacs → bridge), answered by `x-test-text {path, text}`:
  the bridge's current text of `path`.
- `x-test-peer {id, name, color, path?, pos?}` (Emacs → bridge): make a peer
  appear, as a `peer` message.
