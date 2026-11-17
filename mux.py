#!/usr/bin/env python3
"""mux.py — Event-driven AF_UNIX socket <-> stdio JSON-lines bridge for Tern `window.luau`.

Spawned once per Tern window via `tern.process.spawn`. Eliminates filesystem timer polling,
ephemeral loopback TCP servers, and Wayland unfocused-window wakeup workarounds:
- Incoming client lines on `w-<pid>.sock` emit `{"id": <cid>, "req": <obj>}` on stdout,
  waking `window.luau`'s `stdout` callback natively on Tern's UI VM thread.
- Replies written by `window.luau` to stdin (`{"id": <cid>, "reply": <obj>, "keep_open": bool}`)
  are forwarded straight back down client `<cid>`'s AF_UNIX socket.
- Client disconnects emit `{"id": <cid>, "disconnected": true}` so `window.luau` drops stale waiters.
- When `window.luau` unloads or reloads (stdin EOF or SIGTERM/SIGINT), open clients receive
  `{"_reload": true}` so long-running `dispatch` calls seamlessly re-attach via `op="await"`.
"""

from __future__ import annotations

import json
import os
import selectors
import signal
import socket
import stat
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ClientConn:
    cid: int
    sock: socket.socket
    in_buf: bytearray = field(default_factory=bytearray)
    dispatched: bool = False


def ensure_secure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or st.st_uid != os.getuid():
        raise SystemExit(f"mux: insecure IPC directory {path}")
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def send_json_line(sock: socket.socket, obj: dict[str, Any]) -> bool:
    raw = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    try:
        sock.sendall(raw)
        return True
    except OSError:
        return False


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: mux.py <ipc_dir>\n")
        return 2

    ipc_dir = Path(sys.argv[1])
    ensure_secure_dir(ipc_dir)

    # Clean up any dead w-*.sock leftovers in ipc_dir
    for old in ipc_dir.glob("w-*.sock"):
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.05)
            probe.connect(str(old))
        except ConnectionRefusedError:
            try:
                old.unlink(missing_ok=True)
            except OSError:
                pass
        except OSError:
            pass
        finally:
            probe.close()

    sock_path = ipc_dir / f"w-{os.getpid()}.sock"
    try:
        sock_path.unlink(missing_ok=True)
    except OSError:
        pass

    old_umask = os.umask(0o077)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(str(sock_path))
        os.chmod(sock_path, 0o600)
    finally:
        os.umask(old_umask)
    srv.listen(64)
    srv.setblocking(False)

    stdin_fd = sys.stdin.fileno()
    os.set_blocking(stdin_fd, False)

    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False)
    os.set_blocking(wake_w, False)

    sel = selectors.DefaultSelector()
    sel.register(srv, selectors.EVENT_READ, data="accept")
    sel.register(stdin_fd, selectors.EVENT_READ, data="stdin")
    sel.register(wake_r, selectors.EVENT_READ, data="wake")

    clients: dict[int, ClientConn] = {}
    next_cid = 1
    stdin_buf = bytearray()
    stopping = False

    def handle_sig(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.set_wakeup_fd(wake_w, warn_on_full_buffer=False)
    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    def close_client(cid: int, notify_vm: bool = False) -> None:
        conn = clients.pop(cid, None)
        if conn is None:
            return
        try:
            sel.unregister(conn.sock)
        except Exception:
            pass
        try:
            conn.sock.close()
        except OSError:
            pass
        if notify_vm and conn.dispatched:
            emit({"id": cid, "disconnected": True})

    emit({"type": "ready", "pid": os.getpid(), "sock": str(sock_path)})

    try:
        while not stopping:
            try:
                events = sel.select(timeout=None)
            except InterruptedError:
                continue

            for key, _mask in events:
                if key.data == "wake":
                    try:
                        os.read(wake_r, 256)
                    except OSError:
                        pass
                    if stopping:
                        break
                elif key.data == "accept":
                    while True:
                        try:
                            csock, _ = srv.accept()
                        except BlockingIOError:
                            break
                        except OSError:
                            break
                        csock.setblocking(True)
                        csock.settimeout(2.0)
                        cid = next_cid
                        next_cid += 1
                        conn = ClientConn(cid=cid, sock=csock)
                        clients[cid] = conn
                        sel.register(csock, selectors.EVENT_READ, data=conn)

                elif key.data == "stdin":
                    while True:
                        try:
                            chunk = os.read(stdin_fd, 65536)
                        except BlockingIOError:
                            break
                        except OSError:
                            chunk = b""
                        if not chunk:
                            stopping = True
                            break
                        stdin_buf.extend(chunk)

                    while True:
                        nl = stdin_buf.find(b"\n")
                        if nl < 0:
                            break
                        line = bytes(stdin_buf[:nl]).decode("utf-8", errors="replace").strip()
                        del stdin_buf[: nl + 1]
                        if not line:
                            continue
                        try:
                            msg = json.loads(line)
                        except Exception:
                            continue
                        cid = int(msg.get("id", 0))
                        conn = clients.get(cid)
                        if conn is None:
                            continue
                        reply = msg.get("reply", {"ok": False, "error": "empty reply"})
                        keep_open = bool(msg.get("keep_open", False))
                        ok_send = send_json_line(conn.sock, reply)
                        if not ok_send or not keep_open:
                            close_client(cid, notify_vm=not ok_send and keep_open)

                elif isinstance(key.data, ClientConn):
                    conn = key.data
                    try:
                        data = conn.sock.recv(65536)
                    except BlockingIOError:
                        continue
                    except OSError:
                        data = b""

                    if not data:
                        close_client(conn.cid, notify_vm=True)
                        continue

                    conn.in_buf.extend(data)
                    if len(conn.in_buf) > 4 * 1024 * 1024:
                        send_json_line(conn.sock, {"ok": False, "error": "request too large (>4 MiB)"})
                        close_client(conn.cid, notify_vm=False)
                        continue

                    nl = conn.in_buf.find(b"\n")
                    if nl >= 0 and not conn.dispatched:
                        raw_line = bytes(conn.in_buf[:nl]).decode("utf-8", errors="replace").strip()
                        del conn.in_buf[: nl + 1]
                        try:
                            req = json.loads(raw_line)
                        except Exception as exc:
                            send_json_line(conn.sock, {"ok": False, "error": f"invalid JSON request: {exc}"})
                            close_client(conn.cid, notify_vm=False)
                            continue
                        conn.dispatched = True
                        emit({"id": conn.cid, "req": req})
    finally:
        signal.set_wakeup_fd(-1)
        for cid, conn in list(clients.items()):
            send_json_line(conn.sock, {"_reload": True})
            close_client(cid, notify_vm=False)
        try:
            sel.close()
        except Exception:
            pass
        for fd in (wake_r, wake_w):
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            srv.close()
        except OSError:
            pass
        try:
            sock_path.unlink(missing_ok=True)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
