"""Live (non-batch) check of emacs-collab's idle-timer acks in a separate Emacs server."""
import os, subprocess, sys, time

REPO = os.path.expanduser("~/git_shit/emacs-collab.el")
NAME = f"ectest-{os.getpid()}"

def ec(form):
    r = subprocess.run(["emacsclient", "-s", NAME, "--eval", form], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise SystemExit(f"emacsclient failed: {r.stderr.strip()}\nform: {form}")
    return r.stdout.strip()

subprocess.run(["emacs", "-Q", f"--daemon={NAME}", "-L", REPO,
                "--eval", "(progn (require 'ert) (load (expand-file-name \"test/emacs-collab-test.el\" \"%s\")))" % REPO],
               check=True, capture_output=True, timeout=60)
ok = True
try:
    # Connect on a temp copy of the fixture, visit a.txt.
    ec("""(progn
      (setq live-dir (emacs-collab-test--tmpdir))
      (copy-directory (expand-file-name "conformance/fixture/" emacs-collab-test--dir) live-dir nil t t)
      (add-hook 'emacs-collab-message-functions #'emacs-collab-test--collect)
      (setq live-conn (emacs-collab-connect
                       (list "python3" (expand-file-name "bridge-ref/loopback.py" emacs-collab-test--dir) "--test")
                       (list (cons 'dir live-dir))))
      (emacs-collab-test--wait (lambda () (emacs-collab-conn-ready live-conn)))
      (setq live-buf (emacs-collab-test--visit live-conn live-dir "a.txt"))
      t)""")
    # 1. Remote edits only, then real idle time: Emacs's idle timer must ack them.
    ec("""(dotimes (_ 3)
            (let ((n (length (emacs-collab-test--bridge-text live-conn "a.txt"))))
              (emacs-collab--send live-conn (list :t "x-test-remote" :path "a.txt" :op (vector "R" n)))
              (emacs-collab-test--wait (lambda () (with-current-buffer live-buf (= (buffer-size) (1+ n)))))))""")
    before = ec('(emacs-collab-test--bridge-pending live-conn "a.txt")')
    time.sleep(1.5)  # Emacs sits idle: its ack timer fires on its own
    after = ec('(emacs-collab-test--bridge-pending live-conn "a.txt")')
    print(f"bridge pending after 3 remote edits: {before} -> after 1.5 s idle: {after}")
    ok &= before != "0" and after == "0"
    # 2. Local edits only, then idle: the bridge's ack must empty Emacs's pending.
    ec('(with-current-buffer live-buf (goto-char (point-max)) (insert "local1") (insert "local2") (insert "local3"))')
    p_before = ec('(with-current-buffer live-buf (length (emacs-collab-doc-pending (emacs-collab--doc))))')
    time.sleep(1.5)
    p_after = ec('(with-current-buffer live-buf (length (emacs-collab-doc-pending (emacs-collab--doc))))')
    print(f"emacs pending after 3 local edits: {p_before} -> after 1.5 s idle: {p_after}")
    ok &= p_before != "0" and p_after == "0"
    # 3. Texts agree.
    same = ec('(with-current-buffer live-buf (equal (emacs-collab-test--buf-text) (emacs-collab-test--bridge-text live-conn "a.txt")))')
    print(f"buffer == bridge text: {same}")
    ok &= same == "t"
    ec("(progn (emacs-collab-disconnect live-conn) (with-current-buffer live-buf (set-buffer-modified-p nil)) (kill-buffer live-buf) (delete-directory live-dir t) t)")
finally:
    subprocess.run(["emacsclient", "-s", NAME, "--eval", "(kill-emacs)"], capture_output=True, timeout=30)
print("LIVE ACK TEST:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
