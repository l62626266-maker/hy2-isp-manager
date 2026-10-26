"""Regression: command substitution must not disable the terminal dialog."""
import os
import subprocess
import sys

if os.name != "posix":
    print("[SKIP] PTY interaction needs a POSIX host; CI runs this on Linux")
    sys.exit(0)

import pty

master, slave = pty.openpty()
process = None
try:
    env = dict(os.environ, HY2M_SOURCE_ONLY="1")
    command = r'''
set -euo pipefail
source ./hy2-manager
# whiptail writes its selection on stderr, which choose redirects to its pipe.
whiptail() { printf '1\n' >&2; }
choice=$(choose test menu 1 one 0 exit)
[[ $choice == 1 ]]
printf 'DIALOG_CAPTURE_OK\n'
'''
    process = subprocess.Popen(
        ["bash", "-c", command], stdin=slave, stdout=subprocess.PIPE,
        stderr=slave, env=env, text=True,
    )
    output, _ = process.communicate(timeout=5)
    if process.returncode != 0 or "DIALOG_CAPTURE_OK" not in output:
        raise SystemExit("[FAIL] dialog detection inside command substitution")
    print("[PASS] captured menu retains interactive dialog on PTY")
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    os.close(slave)
    os.close(master)
