#!/usr/bin/env python3
"""Claude Code hook: show what Claude is doing on the band.

Reads the hook's JSON from stdin and hands a notification to a running `openband listen`
(through its local socket, so no Bluetooth is needed in the shell Claude Code runs in).
Never blocks Claude: it gives up quietly when the listener is not running.

  Notification -> "Claude · <project>"  "<what Claude asks>"
  Stop         -> "Claude · <project>"  "Done: <start of the last answer>"
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path


def socket_path() -> Path:
    home = Path(os.environ.get("OPENBAND_HOME", Path.home() / ".config" / "openband"))
    return home / "listen.sock"


def message(event: dict) -> tuple[str, str] | None:
    project = Path(event.get("cwd") or ".").name or "Claude"
    title = f"Claude · {project}"
    kind = event.get("hook_event_name", "")
    if kind == "Notification":
        return title, event.get("message") or "needs you"
    if kind == "Stop":
        last = (event.get("last_assistant_message") or "").strip()
        return title, f"Done: {last}" if last else "Done"
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    msg = message(event)
    path = socket_path()
    if msg is None or not path.exists():
        return 0
    payload = {"title": msg[0], "text": msg[1], "sender": "Claude"}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(3.0)
            s.connect(str(path))
            s.sendall((json.dumps(payload) + "\n").encode())
            s.recv(256)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
