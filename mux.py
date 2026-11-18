#!/usr/bin/env python3
"""mux.py — Cross-platform event-driven socket <-> stdio JSON-lines bridge for Tern `window.luau`.

Works across Linux, macOS, and Windows using only Python 3.10+ standard library:
- Uses `AF_UNIX` stream sockets (`w-<pid>.sock`) on Linux, macOS, and Windows 10/11+, with an
  authenticated `127.0.0.1` loopback fallback (`w-<pid>.tcp` + 256-bit token) if `AF_UNIX` is unavailable.
- Uses `socket.socketpair()` + a lightweight stdin reader thread so `selectors.DefaultSelector()` only
  ever registers genuine sockets (required by Windows WinSock `SelectSelector` and `signal.set_wakeup_fd`).
"""

from __future__ import annotations

import json
import os
import queue
import secrets
import selectors
import signal
import socket
import stat
import sys
import threading
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
    if stat.S_ISLNK(st.st_mode):
        raise SystemExit(f"mux: insecure symlink IPC directory {path}")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise SystemExit(f"mux: IPC directory {path} not owned by current user")
    if os.name != "nt":
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


def _cleanup_stale_endpoints(ipc_dir: Path) -> None:
    if hasattr(socket, "AF_UNIX"):
        for old in ipc_dir.glob("w-*.sock"):
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(0.05)
                probe.connect(str(old))
            except (ConnectionRefusedError, FileNotFoundError):
                try:
                    old.unlink(missing_ok=True)
                except OSError:
                    pass
            except OSError:
                pass
            finally:
                probe.close()

    for old_tcp in ipc_dir.glob("w-*.tcp"):
        try:
            meta = json.loads(old_tcp.read_text(encoding="utf-8"))
            port = int(meta["port"])
        except Exception:
            try:
                old_tcp.unlink(missing_ok=True)
            except OSError:
                pass
            continue
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.05)
            probe.connect(("127.0.0.1", port))
        except ConnectionRefusedError:
            try:
                old_tcp.unlink(missing_ok=True)
            except OSError:
                pass
        except OSError:
            pass
        finally:
            probe.close()


def _bind_server(ipc_dir: Path, pid: int) -> tuple[socket.socket, Path, str | None]:
    """Bind AF_UNIX `w-<pid>.sock` when supported; fall back to authenticated loopback TCP `w-<pid>.tcp`."""
    if hasattr(socket, "AF_UNIX"):
        sock_path = ipc_dir / f"w-{pid}.sock"
        try:
            sock_path.unlink(missing_ok=True)
        except OSError:
            pass
        old_umask = os.umask(0o077) if hasattr(os, "umask") else None
        srv: socket.socket | None = None
        try:
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(str(sock_path))
            if os.name != "nt":
                try:
                    os.chmod(sock_path, 0o600)
                except OSError:
                    pass
            srv.listen(64)
            srv.setblocking(False)
            return srv, sock_path, None
        except OSError:
            if srv is not None:
                try:
                    srv.close()
                except OSError:
                    pass
            try:
                sock_path.unlink(missing_ok=True)
            except OSError:
                pass
        finally:
            if old_umask is not None and hasattr(os, "umask"):
                os.umask(old_umask)

    # Authenticated 127.0.0.1 fallback for environments without AF_UNIX
    token = secrets.token_hex(32)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(64)
    srv.setblocking(False)
    port = int(srv.getsockname()[1])
    tcp_meta = ipc_dir / f"w-{pid}.tcp"
    old_umask = os.umask(0o077) if hasattr(os, "umask") else None
    try:
        tcp_meta.write_text(json.dumps({"port": port, "token": token}), encoding="utf-8")
        if os.name != "nt":
            try:
                os.chmod(tcp_meta, 0o600)
            except OSError:
                pass
    finally:
        if old_umask is not None and hasattr(os, "umask"):
            os.umask(old_umask)
    return srv, tcp_meta, token


def _make_wake_socketpair() -> tuple[socket.socket, socket.socket]:
    try:
        r, w = socket.socketpair()
    except OSError:
        lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lsock.bind(("127.0.0.1", 0))
        lsock.listen(1)
        w = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            w.connect(lsock.getsockname())
            r, _ = lsock.accept()
        finally:
            lsock.close()
    r.setblocking(False)
    w.setblocking(False)
    return r, w


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: mux.py <ipc_dir>\n")
        return 2

    ipc_dir = Path(sys.argv[1])
    ensure_secure_dir(ipc_dir)
    _cleanup_stale_endpoints(ipc_dir)

    pid = os.getpid()
    srv, endpoint_path, auth_token = _bind_server(ipc_dir, pid)

    wake_r, wake_w = _make_wake_socketpair()

    stdin_q: queue.SimpleQueue[bytes | None] = queue.SimpleQueue()

    def _notify_wake() -> None:
        try:
            wake_w.send(b"\x01")
        except OSError:
            pass

    def _stdin_reader() -> None:
        # Use raw `os.read(0, ...)` rather than `sys.stdin.buffer.readline()` so daemon-thread blocking
        # never holds CPython's `BufferedReader` lock during SIGTERM interpreter finalization.
        buf = bytearray()
        while True:
            try:
                chunk = os.read(0, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                if buf:
                    stdin_q.put(bytes(buf))
                    buf.clear()
                stdin_q.put(None)
                _notify_wake()
                break
            buf.extend(chunk)
            woke = False
            while True:
                nl = buf.find(b"\n")
                if nl < 0:
                    break
                line = bytes(buf[: nl + 1])
                del buf[: nl + 1]
                stdin_q.put(line)
                woke = True
            if woke:
                _notify_wake()

    threading.Thread(target=_stdin_reader, name="mux-stdin", daemon=True).start()

    sel = selectors.DefaultSelector()
    sel.register(srv, selectors.EVENT_READ, data="accept")
    sel.register(wake_r, selectors.EVENT_READ, data="wake")

    clients: dict[int, ClientConn] = {}
    next_cid = 1
    stopping = False

    def handle_sig(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    has_wakeup_fd = False
    try:
        signal.set_wakeup_fd(wake_w.fileno(), warn_on_full_buffer=False)
        has_wakeup_fd = True
    except (ValueError, OSError):
        pass

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

    def drain_stdin_queue() -> None:
        nonlocal stopping
        while True:
            try:
                item = stdin_q.get_nowait()
            except queue.Empty:
                break
            if item is None:
                stopping = True
                break
            line = item.decode("utf-8", errors="replace").strip()
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

    emit({"type": "ready", "pid": pid, "sock": str(endpoint_path)})

    try:
        while not stopping:
            try:
                events = sel.select(timeout=None)
            except InterruptedError:
                continue

            for key, _mask in events:
                if key.data == "wake":
                    while True:
                        try:
                            if not wake_r.recv(256):
                                break
                        except BlockingIOError:
                            break
                        except OSError:
                            break
                    drain_stdin_queue()
                    if stopping:
                        break

                elif key.data == "accept":
                    while True:
                        try:
                            csock, _ = srv.accept()
                        except (BlockingIOError, OSError):
                            break
                        csock.setblocking(True)
                        csock.settimeout(2.0)
                        cid = next_cid
                        next_cid += 1
                        conn = ClientConn(cid=cid, sock=csock)
                        clients[cid] = conn
                        sel.register(csock, selectors.EVENT_READ, data=conn)

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
                        if auth_token is not None:
                            if not isinstance(req, dict) or req.pop("_token", None) != auth_token:
                                send_json_line(conn.sock, {"ok": False, "error": "unauthorized mux client"})
                                close_client(conn.cid, notify_vm=False)
                                continue
                        conn.dispatched = True
                        emit({"id": conn.cid, "req": req})
    finally:
        if has_wakeup_fd:
            try:
                signal.set_wakeup_fd(-1)
            except (ValueError, OSError):
                pass
        for cid, conn in list(clients.items()):
            send_json_line(conn.sock, {"_reload": True})
            close_client(cid, notify_vm=False)
        try:
            sel.close()
        except Exception:
            pass
        for s in (wake_r, wake_w, srv):
            try:
                s.close()
            except OSError:
                pass
        try:
            endpoint_path.unlink(missing_ok=True)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
