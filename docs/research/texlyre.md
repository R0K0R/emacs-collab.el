# TeXlyre collaboration protocol, for a non-browser bridge

Sources: upstream TeXlyre v0.11.0 (paths below are relative to its repository), y-webrtc v10.3.0 (`yjs/y-webrtc`, `src/y-webrtc.js`, `src/crypto.js`, `bin/server.js`), y-codemirror.next 0.3.5. The Nix store `result` holds only the built `dist/` (minified), so I read source.

## 1. Room model

- **A project is an id, not a doc.** `src/utils/urlUtils.ts`: project id is `crypto.randomUUID()` (legacy: 20-32 char `[a-z0-9]`). The project "URL" is `yjs:<uuid>`.
- **There are many Y.Docs per project, one WebRTC room each.** `src/services/CollabService.ts` `createOnlineConnection`: `roomName = "${projectId}-${collectionName}"`, and the doc is a fresh `new Y.Doc()` (no subdocs). Collections in use:
  - `yjs_metadata`: project index (`src/components/app/EditorApp.tsx:850`, `src/contexts/CollabContext.tsx`).
  - `yjs_<docId>`: one per text document (`src/hooks/editor/useEditorView.ts:573`).
  - `chat` (`src/contexts/ChatContext.tsx:60`) and `file_sync` (`src/contexts/FileSyncContext.tsx:831`).
  - Example room name: `3f2a...-uuid-yjs_metadata`. The doc id is `Math.random().toString(36).substring(2,15)` (`FileTreeContext.tsx:296`).
- **Metadata doc** (`yjs_metadata`) is a single `Y.Map` named `data` (`CollabContext.tsx:139`, creation in `src/services/AuthService.ts:~508`), with these keys:
  - `documents`: a plain JSON array of `{id, name, content:'', createdAt}`. It is NOT a Y.Array. `name` is the file path (e.g. `main.tex`, `sec/intro.tex`). The array is written whole, so concurrent edits are last-writer-wins.
  - `currentDocId`, `cursors: []`, `chatMessages: []`.
  - `projectMetadata`: `{name, description, type, group, mainFile, compilerId, latexEngine, trackedFiles, ...}` (`src/types/documents.ts`).
  - `changeData` (`CollabContext.tsx:199`) deletes every key and re-sets it inside one transaction. Writing from a bridge must mimic this or accept clobbering, so add a doc by replacing the whole `documents` value, not by appending.
- **File text:** `doc.getText('codemirror')` (a plain Y.Text, not XmlText) in room `<projectId>-yjs_<docId>`. Every call site uses this key (`useEditorView.ts:584`, `CollabService.ts` `updateDocumentContent`, `ProjectDataService.ts:145`). Editing is through y-codemirror.next 0.3.5.
- **File tree:** there is no Yjs file tree. The tree lives in each browser's IndexedDB `fileStorageService`, with records carrying `path` and `documentId`. The only shared tree info is `documents[].name` (path to docId). Folder structure is implicit in the paths. Text files that are not "linked" to a document are not collaborative (`isEditingFile`).
- **Binary files (images, PDFs):** never in Yjs. They sit in IndexedDB and are moved by the FilePizza integration (WebRTC via PeerJS, server `https://filepizza.texlyre.org`, README line ~160). `file_sync` is a Y.Map named `fileSync` (key = user id, value = that user's local file list) used only for metadata/negotiation (`FileSyncContext.tsx:209,298`). A bridge gets no binary content over y-webrtc. It would have to speak FilePizza/PeerJS, which is out of scope.
- **Doc rooms only exist while someone opens them.** `PeerDocumentTrackingService.ts` publishes `openDocs: [docId]` in the `yjs_metadata` awareness. Peers that see a remote `openDocs` open that doc as a background connection. So a bridge must join `yjs_metadata`, read `documents`, and then join `<pid>-yjs_<docId>` per file. It should also publish its own `openDocs` so browsers keep the rooms alive.

## 2. Transport

**y-webrtc** (default, `collab-provider-type: "webrtc"`; `src/extensions/yjs/CollabWebrtc.ts`):
- `new WebrtcProvider(roomName, doc, {signaling, password})`. No `peerOpts`, `maxConns` or `filterBcConns` are passed, so simple-peer defaults apply (Google/Twilio STUN, no TURN).
- Signaling URLs come from the user setting `collab-signaling-servers` (comma-separated). `userdata.json` default is `wss://ywebrtc.texlyre.org`. `ws://` URLs are dropped when the page is https (`CollabService.validateSignalingServers`). With your flake's `--signaling`, `userdata.json` is rewritten per request to `wss://<Host>/ywebrtc` (texlyre-serve.sh:150-190), a Caddy proxy to loopback y-webrtc server :4444.
- **Password is effectively unused.** No caller passes `password` (`CollabContext.tsx`, `EditorContext.getCollabOptions`, `FileTreeContext`, `ChatContext`, `FileSyncContext` all omit it). So `key = null` and nothing is encrypted. The crypto code exists in y-webrtc but is dormant in TeXlyre 0.11.0.
- If a password were set (`src/crypto.js`):
  - Key: `crypto.subtle` PBKDF2, password = UTF-8 secret, **salt = UTF-8 roomName**, 100000 iterations, SHA-256, derived to AES-GCM 256.
  - Encrypted: the signaling `data` payload, as JSON-ish lib0 `writeAny`, encrypted and base64-ed. The BroadcastChannel messages are encrypted too.
  - Wire format of an encrypted blob: `varString "AES-GCM"`, `varUint8Array iv(12)`, `varUint8Array ciphertext`.
  - The WebRTC data channel itself is NOT app-layer encrypted (DTLS only).
- **Signaling protocol** (`bin/server.js`): JSON text frames over a WebSocket.
  - `{type:'subscribe'|'unsubscribe', topics:[room]}`.
  - `{type:'publish', topic:room, data:<obj>}`. The server echoes the same message to all subscribers, adding `clients`.
  - `{type:'ping'}` gets `{type:'pong'}`. The server also sends WS pings every 30 s and drops clients that don't pong.
  - `data` objects are `{type:'announce', from:peerId}` or `{type:'signal', to, from, token, signal}`. `token` is `Date.now()+Math.random()` for glare resolution (a higher local token rejects the remote offer). `signal` is simple-peer's JSON: `{type:'offer'|'answer', sdp}` or `{candidate:{...}}`. Possibly also `renegotiate` and `transceiverRequest`.
  - `peerId` is a uuidv4. The announce flow: on connect, subscribe and publish an announce. A peer that receives an announce creates a `WebrtcConn` as initiator and sends the offer. `maxConns` is 20-34.
- **Data channel frames:** each is a raw lib0-encoded y-protocols message:
  - `varUint type` (0 sync, 1 awareness, 3 queryAwareness, 4 bcPeerId).
  - Sync (0) is the standard y-protocols sync (step1 / step2 / update), the same as y-websocket. Awareness (1) is `varUint8Array` awareness update.
  - On connect, both sides send sync step1 and their awareness. Updates are broadcast to all connected peers.
- **BroadcastChannel:** same-origin tabs only (channel name = room name, same message types). Irrelevant for a bridge (no BC access).
- **Awareness timeout:** setting `collab-awareness-timeout` (30 s). `CollabService.ts:200` drops remote states whose `state.lastSeen` is older than the timeout, but only if the state has `lastSeen`. Nothing in the repo sets `lastSeen` (grep), so the check is inert. Normal y-protocols 30 s awareness timeout applies.

**y-websocket mode** (`collab-provider-type: "websocket"`, `CollabWebsocket.ts`):
- `new WebsocketProvider(serverUrl, roomName, doc, {params})` (client package y-websocket ^3.1.0). The URL is `${serverUrl}/${roomName}` (default server `ws://localhost:1234`, fallback `ws://yweb.localhost:8082/`). The room name is identical to the WebRTC one: `<pid>-yjs_<docId>`.
- With your flake (`--websocket`, texlyre-serve.sh:171-178): `wss://<host>/yws` is proxied to `texlyre-ywebsocket-server` (y-websocket 1.5.4 server, loopback :1234). Final URL is e.g. `wss://host:8443/yws/<pid>-yjs_metadata`.
- Wire format: standard y-websocket (varUint 0 sync, 1 awareness, 3 auth, 2 queryAwareness).
- **In-memory only** unless `YPERSISTENCE` is set (`bin/utils.js`, 1.5.4). `ywebsocket.nix` doesn't set it, so docs vanish on server restart. While the server runs, the doc survives with no browser connected.
- The `websocketParams` option exists but is never populated, so there is no auth.

## 3. Identity / auth / share links

- All accounts are local: `AuthService.ts` keeps users in IndexedDB. A `User` has `{id, username, name, passwordHash, color, colorLight, isGuest, ...}` (`src/types/auth.ts`). Colors come from `generateRandomColor` (`colorUtils.ts`).
- Your patch (`auto-login.py`) auto-creates a guest account on every browser. Nothing server-side authenticates (server never sees users).
- A project is `{docUrl: "yjs:<uuid>", name, ...}` in the local project DB. The metadata doc (above) is the shared part.
- **Share link** (`EditorApp.tsx:141`): `${origin}${pathname}#yjs:<uuid>`, with optional `&doc:<id>&file:<path>&compile:<x>` fragments (`parseUrlFragments`). It contains the project UUID only, with no password and no signaling URL. The recipient's own settings determine the signaling/relay server, so a bridge needs: the project UUID, the signaling URL or relay URL (same one the browsers use), and (never, in 0.11.0) a password. Anyone who knows the UUID and reaches the same signaling server can join. A new client has no local data, so it bootstraps entirely from peers.

## 4. Server-side persistence

- None for TeXlyre itself: the editor is static files (README "keeps no server-side state"; `ProtectSystem=strict`, only Caddy CA in `StateDirectory`). Each peer persists its docs with y-indexeddb (`CollabService.ts:~127`, db name `texlyre-project-<pid>-<collection>`).
- y-webrtc signaling is stateless (topic to socket sets). Docs only exist on peers.
- **No browser peer online means no data** in WebRTC mode. A bridge that is the only peer holds only its own copy. To make it durable, persist the Y.Doc state yourself (e.g. `encode_state_as_update` to disk) and re-sync on start. A bridge with persisted state can seed peers when they come online (CRDT merge is safe, since both sides are the same doc lineage).
- Websocket mode: the relay keeps the doc in memory (see above).

## 5. Awareness payload

Per room, published by `CollabService.setUserInfo` (`CollabService.ts:266`) and y-codemirror.next:
- `user: {id, username, name: <username>, color, colorLight}`. Duplicated as top-level `name` and `username` fields (for compatibility with other consumers). y-codemirror.next reads `user.name`, `user.color`, `user.colorLight` (defaults `#30bced`, `Anonymous`, `color+'33'`).
- `cursor: {anchor, head}`, both `Y.RelativePosition` JSON (`{type, tname, item, assoc}`) created with `createRelativePositionFromTypeIndex(ytext, idx)`. A null cursor means no focus. Resolve with `createAbsolutePositionFromRelativePosition` against the `codemirror` Y.Text (y-remote-selections.js:159-198).
- `openDocs: ["<docId>", ...]` in the `yjs_metadata` awareness (`PeerDocumentTrackingService.ts`).
- Extra fields: `sharedTools` ads (`SharedToolsContext.tsx:211`), `accountPeer` for Chelys (`RendezvousRoom.ts`).
- An external client sends `user` plus `cursor` with relative positions, and should set `user` with `name`, `color`, `colorLight`. In rooms other than metadata, the cursor is only drawn if the peer has the doc open.

## 6. Feasibility

| Piece | Rust (yrs + webrtc-rs) | Python (pycrdt + aiortc) |
|---|---|---|
| Y.Text `codemirror`, Y.Map `data` | direct: `yrs` `get_or_insert_text/map`. The `documents` value is `Any` JSON | direct |
| y-protocols sync + awareness | `yrs::sync` (`Protocol`, `Awareness`) matches y-protocols | pycrdt has `pycrdt.sync` / `Awareness` (check version) |
| y-websocket | easy (`y-sync`/`yrs-warp` or hand-rolled over tungstenite) | `pycrdt-websocket` client side is available |
| Signaling WS JSON | trivial (tungstenite + serde_json) | trivial |
| simple-peer SDP/ICE semantics | **hard part**: need `{type,sdp}` and `{candidate}` JSON, trickle ICE, glare token logic | same with aiortc (no trickle by default; send candidates after gathering) |
| Data channel | binary messages, plain `RTCDataChannel`, no extra framing | aiortc supports it |
| Peer discovery | announce/offer handled by hand | same |
| Password crypto | PBKDF2/AES-GCM, easy (`ring`/`aes-gcm`) but inactive in TeXlyre | `cryptography` |

Details and risks:
- **simple-peer handshake is the one hard part.** Data channel label is a random string and negotiation uses `initiator`. When you receive an `announce` you create the offer, otherwise answer an offer. Candidates are separate `{candidate}` signals. Trickle is on by default. A bridge should answer glare with the token rule (`localToken > remoteToken` rejects the offer).
- **ICE/NAT:** browsers use STUN only, and no TURN is deployed. Across the tailnet it works if the UDP host candidates are reachable, so a bridge on gb4 with Tailscale IPs needs ICE to gather tailscale0 candidates (webrtc-rs: configure interface filter / `SettingEngine`). Often easier: the **y-websocket relay** (`--websocket`) sidesteps all of this and is the recommended path for a bridge, since it gets a plain WS URL and a standard protocol. The cost is that all browsers must use websocket mode (setting `collab-provider-type`), because rooms are not shared between providers.
- **Signaling quirks:** the server pings every 30 s, so reply to WS pings. Topics are room names. Data is JSON, with a base64 string only when a password is set. Need to subscribe to every room and re-announce on reconnect. You can still ignore BroadcastChannel entirely.
- **Rooms are plentiful:** N+3 rooms per project, one signaling subscription each, and one PeerConnection per (peer, room). A browser with 10 docs open makes 10+ connections to the bridge. Consider limiting joins to docs the Emacs side has open.
- **Metadata hazards:** `documents` is a whole-array LWW value. Concurrent rename/create/delete from several clients can drop entries. Treat it as read-only except for deliberate new-file creation, and then also create the file's IndexedDB record in browsers? You can't. A browser only shows doc if a file record with the matching `documentId` exists in its local file DB, so a bridge-created doc may not appear in a browser tree until "linked". Reading is the reliable direction.
- **Same-lineage requirement:** a new bridge doc with no state is fine (it syncs). Writing text: use Y.Text `insert/delete` diffs (not delete-all/insert-all as `updateDocumentContent` does), to keep cursors/undo sane.
- Yjs versions: yjs 13.6.x, lib0 0.2.117 in the browser. yrs v1 updates are compatible. Use `gc` default on, as browsers do.

## 7. Licenses

- TeXlyre: **AGPL-3.0** (`LICENSE`, GitHub API `license.spdx_id` and `texlyre.nix` `agpl3Only`). Chelys, the companion app, is also AGPL-3.0. A separate bridge that speaks the protocol and doesn't copy TeXlyre code isn't a derivative, but copying code from TeXlyre pulls in AGPL.
- y-webrtc: **MIT** (`LICENSE`, Kevin Jahns, `package.json` `"license": "MIT"`). y-websocket and yjs are MIT. simple-peer is MIT (not verified here).
