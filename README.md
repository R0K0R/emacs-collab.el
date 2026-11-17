# emacs-collab.el

Emacs client for the emacs-collab protocol (see `PROTOCOL.md`): a bridge
subprocess speaks the protocol on stdin/stdout and the collaboration
service's own protocol on the network; `emacs-collab.el` syncs the buffers,
`emacs-collab-layout.el` builds the project windows, and
`emacs-collab-ot.el` is the operational-transform core.

## Choosing the local mirror directory

Workspaces that mirror a remote project (`overleaf-workspace`,
`texlyre-workspace`, `noteworthy-workspace`) never hardcode where the copy
lives. They call

```elisp
(emacs-collab-read-mirror-dir SERVICE PROJECT-KEY &optional SUGGESTION FORCE)
```

and pass the result to the bridge as `mirror_dir`.

- A directory remembered for (SERVICE, PROJECT-KEY) is returned without a
  prompt (and created if it vanished), unless FORCE (the workspaces' `C-u`).
- Otherwise `read-directory-name` asks ("Local copy of PROJECT in: "),
  starting from the remembered directory, else SUGGESTION, else
  `emacs-collab-mirror-root`/SERVICE/PROJECT when that option is set, else
  `default-directory`. The directory is created.
- The choice is remembered in `emacs-collab-mirror-state-file` (default
  `emacs-collab-mirrors.eld` next to the layout state; written atomically).
  `M-x emacs-collab-forget-mirror` drops one.
- A `.emacs-collab` marker file in the mirror records service and project.
  A directory marked as a different project is refused with a `user-error`;
  a non-empty directory without a marker only draws a warning.

`emacs-collab-mirror-root` defaults to nil.
