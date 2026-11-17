# bridge-ref

Reference code for the emacs-collab protocol (`../PROTOCOL.md`). Python 3, standard library only.

- `ot.py`: ot.js-style text operations over code points (`apply`, `compose`, `transform`, `normalize`, `from_change`, ...).
- `loopback.py`: a complete bridge whose "service" is a local directory. `open {params:{dir}}` makes that directory the mirror. It is single-user: edits only sync between Emacs and the bridge's in-memory text. Unattached files are written to disk atomically, attached files only on `detach`. It advertises `cursors`, `chat` and `files`, and with `--test` accepts the `x-test-*` messages.
- `test_ot.py`: unit and randomized property tests for `ot.py`.

## Run

    python3 bridge-ref/loopback.py            # speaks the protocol on stdin/stdout
    python3 bridge-ref/loopback.py --test     # also accepts x-test-*

Emacs would use argv `("python3" "/path/to/bridge-ref/loopback.py")` with open params `{"dir": "/some/dir"}`.

## Tests

    python3 -m unittest bridge-ref/test_ot.py
    python3 conformance/run.py --bridge "python3 bridge-ref/loopback.py"

The conformance runner plays the Emacs side against any bridge (it appends `--test`). `--params '{"dir":"{dir}"}'` sets the open params; `{dir}` expands to a temporary copy of `conformance/fixture/`. Use `--rounds N` to change the number of random concurrent rounds (default 50), `--only NAME` for one scenario, and `CONF_VERBOSE=1` to show the bridge's stderr.
