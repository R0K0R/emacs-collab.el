# Overleaf real-time protocol: research notes (2026-11)

Sources, read at the HEAD of each in 2026: the overleaf/overleaf monorepo (server,
2026-09-17), Overleaf Workshop (OW, iamhyc/overleaf-workshop, AGPL-3.0, 2026-10-03)
and nvim-overleaf (NVO, mei28/nvim-overleaf, MIT, 2026-04-06). Two server changes
since 2024 matter. The server only accepts the "v2" connect, where you pass
`?projectId=` and the server joins the project for you. And migrated projects can
have docs of type `history-ot`, which neither client supports.

## Auth
- **Session cookie:** `overleaf_session2` on overleaf.com and `overleaf.sid` on
  self-hosted CE (verified on yulee's CE 6.3.3; older CE used `sharelatex.sid`;
  the name is settable via `COOKIE_NAME`).
- **GCLB (overleaf.com only):** GET `/socket.io/socket.io.js` and merge its
  Set-Cookie. Also merge any Set-Cookie from the handshake.
- **CSRF:** `<meta name="ol-csrfToken">` (and `ol-user_id`) from GET `/project`,
  sent as the `X-Csrf-Token` header. REST only; the websocket doesn't use it.
- **Password login (CE):** GET `/login`, scrape `_csrf`, POST JSON
  `{_csrf,email,password}`, which answers 302 to `/project`. overleaf.com has a
  captcha, so use a pasted cookie there.

## Transport: socket.io 0.9 (Overleaf's fork), not EIO v4
- **Handshake:** `GET {origin}/socket.io/1/?projectId=<id>&t=<ms>` with the
  Cookie and Origin headers. The body is `sid:heartbeatTimeout:closeTimeout:transports`
  (yulee CE answered `…:60:60:websocket,xhr-polling`).
- **Websocket:** `wss://host/socket.io/1/websocket/<sid>?projectId=<id>&t=…`,
  with the same headers.
- **Missing `projectId`:** the server emits
  `connectionRejected {message:'missing/bad ?projectId=...'}`.
- **Optional pings:** `esh=1&ssp=1` turns on server pings `serverPing(id, ts,
  transport, sid)`, which expect
  `clientPong(id, ts, serverTransport, serverSid, clientTransport, clientSid)`.
- **Frames:**
  - `1::` connect;
  - `2::` heartbeat: echo it, and send one every ~0.8× the timeout;
  - `5:<id>+::{"name","args"}` event with ack;
  - `6:::<id>+[err,…]` ack, error-first;
  - `0::` disconnect.

## Joining
- **Project:** after connect the server emits `joinProjectResponse {publicId,
  project, permissionsLevel, protocolVersion}`. The tree is
  `project.rootFolder[0]`: `{_id,name,docs[],fileRefs[],folders[]}`, nested.
- **Doc:** `joinDoc(docId, [fromVersion], [{encodeRanges?, supportsHistoryOT?,
  age?}], cb)`, a strict schema. It answers `cb(err, lines, version, updates,
  ranges, type, {canSkipLeaveDoc})`.
  - In `sharejs-text-ot` docs, `lines` are UTF-8 packed as Latin-1; decode with
    `decodeURIComponent(escape(s))`.
  - `fromVersion` returns the missed `updates`.
- **history-ot docs:** joinDoc fails with `client does not support history-ot`
  unless `supportsHistoryOT:true` is passed. Then `lines` is a raw StringFileData
  and ops are overleaf-editor-core TextOperations (retain/insert/delete).
- **leaveDoc:** a no-op now.

## Sending edits
- **Call:** `applyOtUpdate(docId, {doc?, op, v, lastV?, hash?, dupIfSource?, meta?:{tc?}}, cb)`.
- **Strict schema:**
  - `op` must be non-empty (an empty op makes the server disconnect), made of
    `{p,i}` / `{p,d}` / `{p,c,t}`, each with an optional `u`;
  - `meta` may only contain `tc`;
  - op strings are plain Unicode, not Latin-1 packed.
- **The emit callback means "queued" only. The ack is `otUpdateApplied {v, doc}`
  without `op`.**
- **Resend:** with no ack within 5 s, resend with `dupIfSource:[own publicIds]`.
- **Hash (optional):** `sha1("blob " + utf16len + "\0" + utf8(str))`, checked only
  when `v` equals the server version.
- **Errors:** `otUpdateError` is followed by a disconnect (`Delete component does
  not match`, `Invalid hash`, `update is too large`, max doc size 2 MiB). Recover
  by reconnecting and rejoining with `fromVersion`, or a fresh join.

## Receiving edits
- **Filter by doc:** updates are broadcast to the project room, so ignore docs
  you haven't joined.
- **Order:** apply strictly at `update.v == localVersion`, buffering
  out-of-order ones.
- **Own ops:** an update whose `meta.source` is your publicId is your own echo;
  treat it as an ack.
- **Positions:** UTF-16 code units. The server turns surrogates in inserts into
  U+FFFD, so emoji are lost.
- **Prior art:** NVO has an inflight/pending state machine; OW does no OT
  (diff3 on save).

## Other events
- **Cursors:**
  - send `clientTracking.updatePosition({row, column, doc_id})`;
  - query `clientTracking.getConnectedUsers(cb)`;
  - receive `clientTracking.clientUpdated` and `clientTracking.clientDisconnected`.
- **Tree** (the server spells it "recive"): `reciveNewDoc(parentId, doc)`,
  `reciveNewFile`, `reciveNewFolder`, `reciveEntityRename(id, name)`,
  `reciveEntityMove(id, folderId)`, `removeEntity(id)`.
- **Compile (REST):** `POST /project/:id/compile` with the CSRF header. Not
  needed: compiling is local.
- **Connection control:** `connectionRejected {message:'retry'|'invalid
  session'|…}`, `reconnectGracefully`, `forceDisconnect(msg, delay)`.
- **Teardown:** always close the old socket before reconnecting (OW #309).

## Bugs to avoid when porting NVO (MIT, portable)
- It treats the emit callback as the ack (`version++`).
- It Latin-1-decodes incoming op strings, which it shouldn't.
- Its hash uses UTF-8 length where the server uses UTF-16 length.
- OW can send `op: []`.
