#!/usr/bin/env python3
"""wingman.py — Native Tern TSP (`WindowCx.agents`) & headless worker bridge for coding agents."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

DEFAULT_BRIDGE_TIMEOUT = 5.0
IS_WINDOWS = os.name == "nt"


def home_dir() -> Path:
    return Path.home()


def active_omp_agent_dir() -> Path:
    """Resolve the active omp agent directory honoring OMP_PROFILE, PI_PROFILE, XDG_DATA_HOME, and PI_CODING_AGENT_DIR."""
    profile = os.environ.get("OMP_PROFILE") or os.environ.get("PI_PROFILE")
    xdg_data = os.environ.get("XDG_DATA_HOME")
    if xdg_data and (Path(xdg_data) / "omp").is_dir():
        root = Path(xdg_data) / "omp"
        return (root / "profiles" / profile) if profile else root

    base = Path(os.environ.get("PI_CONFIG_DIR", home_dir() / ".omp"))
    if profile:
        return base / "profiles" / profile / "agent"
    override = os.environ.get("PI_CODING_AGENT_DIR")
    if override:
        return Path(override).expanduser()
    return base / "agent"


def sessions_root() -> Path:
    if os.environ.get("DEJA_OMP_ROOT"):
        return Path(os.environ["DEJA_OMP_ROOT"]).expanduser()
    d = active_omp_agent_dir()
    return d / "sessions"


def _is_executable(path: Path) -> bool:
    if not path.is_file():
        return False
    return True if IS_WINDOWS else os.access(path, os.X_OK)


def _subproc_no_window_kwargs() -> dict[str, Any]:
    if IS_WINDOWS and hasattr(subprocess, "CREATE_NO_WINDOW"):
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


def format_command_line(parts: list[str]) -> str:
    """Format argv into a platform-appropriate command string (Windows CreateProcess vs POSIX shell)."""
    if IS_WINDOWS:
        return subprocess.list2cmdline(parts)
    return shlex.join(parts)


def find_omp_bin() -> str:
    """Locate the active `omp` binary across Linux, macOS, and Windows."""
    h = home_dir()
    local_app = Path(os.environ["LOCALAPPDATA"]) if os.environ.get("LOCALAPPDATA") else None
    exe_names = ("omp.exe", "omp.cmd", "omp") if IS_WINDOWS else ("omp",)
    candidates: list[Path] = []
    if local_app is not None:
        for ename in exe_names:
            candidates.append(local_app / "Tern" / "omp" / "bin" / ename)
            candidates.append(local_app / "Programs" / "omp" / ename)
    candidates.extend(
        [
            h / ".local" / "share" / "tern" / "omp" / "bin" / "omp",
            h / "Library" / "Application Support" / "tern" / "omp" / "bin" / "omp",
            h / ".local" / "bin" / ("omp.exe" if IS_WINDOWS else "omp"),
        ]
    )
    for c in candidates:
        if _is_executable(c):
            return str(c.resolve())
    found = shutil.which("omp")
    if found:
        return found
    version_dirs = [
        h / ".local" / "share" / "tern" / "omp" / "versions",
        h / "Library" / "Application Support" / "tern" / "omp" / "versions",
    ]
    if local_app is not None:
        version_dirs.insert(0, local_app / "Tern" / "omp" / "versions")
    for versions_dir in version_dirs:
        if versions_dir.is_dir():
            vers = sorted(
                (p for p in versions_dir.iterdir() if _is_executable(p)),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            if vers:
                return str(vers[0])
    raise SystemExit("error: could not locate `omp` binary on PATH or under Tern's managed directory")


def find_tern_bin() -> str | None:
    """Locate the `tern` CLI binary across Linux, macOS, and Windows (`tern.com` preferred on Windows)."""
    env_exe = os.environ.get("TERN_EXE")
    h = home_dir()
    local_app = Path(os.environ["LOCALAPPDATA"]) if os.environ.get("LOCALAPPDATA") else None
    candidates: list[Path | None] = [Path(env_exe) if env_exe else None]
    if local_app is not None:
        candidates.extend(
            [
                local_app / "Programs" / "Tern" / "tern.com",
                local_app / "Programs" / "Tern" / "tern.exe",
            ]
        )
    candidates.extend(
        [
            h / ".local" / "bin" / ("tern.exe" if IS_WINDOWS else "tern"),
            Path("/Applications/Tern.app/Contents/MacOS/tern"),
            Path("/opt/homebrew/bin/tern"),
            Path("/usr/local/bin/tern"),
        ]
    )
    for c in candidates:
        if c is not None and _is_executable(c):
            return str(c)
    return shutil.which("tern.com") if IS_WINDOWS and shutil.which("tern.com") else shutil.which("tern")


def find_ovnfs_bin() -> str | None:
    """Locate Stencil's `ovnfs` binary across Linux, macOS, and Windows if installed."""
    h = home_dir()
    local_app = Path(os.environ["LOCALAPPDATA"]) if os.environ.get("LOCALAPPDATA") else None
    candidates: list[Path] = []
    if local_app is not None:
        candidates.append(local_app / "Tern" / "ovnfs" / "bin" / "ovnfs.exe")
    candidates.extend(
        [
            h / ".local" / "share" / "tern" / "ovnfs" / "bin" / "ovnfs",
            h / "Library" / "Application Support" / "tern" / "ovnfs" / "bin" / "ovnfs",
            h / ".local" / "bin" / ("ovnfs.exe" if IS_WINDOWS else "ovnfs"),
        ]
    )
    for c in candidates:
        if _is_executable(c):
            return str(c)
    return shutil.which("ovnfs")


def current_tern_pane() -> int | None:
    raw = os.environ.get("TERN_PANE", "").strip()
    return int(raw) if raw.isdigit() else None


def bridge_ipc_dir() -> Path:
    """Resolve the secure IPC directory shared with `window.luau` across Linux, macOS, and Windows."""
    if IS_WINDOWS:
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("TEMP") or r"C:\Temp"
        d = Path(base) / "tern-wingman"
    else:
        rt = os.environ.get("XDG_RUNTIME_DIR", "").strip()
        if rt and len(rt) <= 72:
            d = Path(rt) / "tern-wingman"
        else:
            fallback = home_dir() / ".cache" / "tern-wingman"
            if len(str(fallback)) <= 72:
                d = fallback
            else:
                uid_str = str(os.getuid()) if hasattr(os, "getuid") else "user"
                user = os.environ.get("USER") or uid_str
                d = Path(f"/tmp/tern-wingman-{user}")
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    st = os.lstat(d)
    if stat.S_ISLNK(st.st_mode):
        raise SystemExit(f"error: insecure symlink IPC directory {d}")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise SystemExit(f"error: IPC directory {d} not owned by current user")
    if not IS_WINDOWS:
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
    return d


def _read_json_line(
    sock: socket.socket,
    buf: bytearray,
    deadline: float | None,
) -> dict[str, Any] | None:
    while True:
        nl = buf.find(b"\n")
        if nl >= 0:
            raw = bytes(buf[:nl]).decode("utf-8", errors="replace").strip()
            del buf[: nl + 1]
            if not raw:
                continue
            return json.loads(raw)

        if deadline is not None:
            rem = deadline - time.monotonic()
            if rem <= 0:
                raise TimeoutError("timed out waiting for Tern wingman plugin")
            sock.settimeout(rem)
        else:
            sock.settimeout(None)

        try:
            chunk = sock.recv(65536)
        except socket.timeout as exc:
            raise TimeoutError("timed out waiting for Tern wingman plugin") from exc
        if not chunk:
            return None
        buf.extend(chunk)


def call_bridge(
    payload: dict[str, Any],
    timeout: float | None = DEFAULT_BRIDGE_TIMEOUT,
    on_ack: Callable[[dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    """Send one RPC over AF_UNIX stream socket to `window.luau`'s event-driven `mux.py`."""
    deadline = (time.monotonic() + timeout) if timeout is not None else None
    ipc = bridge_ipc_dir()
    daemon_sock = os.environ.get("TERN_DAEMON_SOCKET") or os.environ.get("TERN_PANE_SOCKET") or ""

    cur_payload = dict(payload)
    cur_payload.setdefault("daemon_socket", daemon_sock)
    ack_pane: int | None = None
    notified_ack = False

    while True:
        endpoints: list[tuple[str, Path]] = []
        if hasattr(socket, "AF_UNIX"):
            endpoints.extend(("unix", p) for p in sorted(ipc.glob("w-*.sock")))
        endpoints.extend(("tcp", p) for p in sorted(ipc.glob("w-*.tcp")))
        need_reload_retry = False

        for kind, sp in endpoints:
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(f"timed out after {timeout}s waiting for Tern wingman plugin")

            wire_payload = dict(cur_payload)
            if kind == "unix":
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                target_addr: Any = str(sp)
            else:
                try:
                    meta = json.loads(sp.read_text(encoding="utf-8"))
                    target_addr = ("127.0.0.1", int(meta["port"]))
                    wire_payload["_token"] = str(meta["token"])
                except Exception:
                    try:
                        sp.unlink(missing_ok=True)
                    except OSError:
                        pass
                    continue
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

            try:
                connect_timeout = 1.0
                if deadline is not None:
                    connect_timeout = max(0.05, min(1.0, deadline - time.monotonic()))
                sock.settimeout(connect_timeout)
                try:
                    sock.connect(target_addr)
                except (ConnectionRefusedError, FileNotFoundError):
                    try:
                        sp.unlink(missing_ok=True)
                    except OSError:
                        pass
                    continue
                except OSError:
                    continue

                wire = (json.dumps(wire_payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
                sock.sendall(wire)

                buf = bytearray()
                while True:
                    frame = _read_json_line(sock, buf, deadline)
                    if frame is None:
                        if ack_pane is not None:
                            need_reload_retry = True
                        break
                    if frame.get("_skip"):
                        break
                    if frame.get("_ack"):
                        ack_pane = int(frame["pane"])
                        if on_ack is not None and not notified_ack:
                            notified_ack = True
                            on_ack(frame)
                        continue
                    if frame.get("_reload"):
                        need_reload_retry = True
                        break
                    return frame
            finally:
                try:
                    sock.close()
                except OSError:
                    pass

            if need_reload_retry:
                break

        if need_reload_retry and ack_pane is not None:
            # `window.luau` reloaded mid-turn; seamlessly re-attach via `await` once the new mux socket binds
            cur_payload = {
                "op": "await",
                "anchor_pane": payload.get("anchor_pane"),
                "target_pane": ack_pane,
                "daemon_socket": daemon_sock,
            }
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(f"timed out after {timeout}s waiting for Tern wingman plugin")
            time.sleep(0.15)
            continue

        # If no active mux socket answered yet (e.g. plugin is mid-reload), retry briefly up to 1.5s / deadline
        now = time.monotonic()
        wait_cap = min(deadline, now + 0.15) if deadline is not None else (now + 0.15)
        if not endpoints and (deadline is None or now + 0.05 < deadline):
            # Bound initial socket discovery wait when plugin is not installed/running
            init_cap = deadline if deadline is not None else (now + DEFAULT_BRIDGE_TIMEOUT)
            deadline = init_cap
            time.sleep(max(0.01, wait_cap - now))
            if time.monotonic() < deadline:
                continue

        raise TimeoutError("no active Tern `wingman` window socket answered")


def inspect_tern(tern_bin: str | None) -> dict[str, Any] | None:
    if not tern_bin:
        return None
    try:
        proc = subprocess.run(
            [tern_bin, "inspect", "--json"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            **_subproc_no_window_kwargs(),
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return json.loads(proc.stdout)
    except Exception:
        pass
    return None


def extract_omp_pane_files(inspect_data: dict[str, Any] | None) -> dict[int, str]:
    """Authoritative map of `pane_id -> resolved omp_session_file` from `tern inspect --json`."""
    pane_files: dict[int, str] = {}
    if inspect_data:
        for p in inspect_data.get("panes", []):
            if "pane" in p and p.get("omp_session_file"):
                pane_files[int(p["pane"])] = str(Path(p["omp_session_file"]).resolve())
    return pane_files


def parse_duration_seconds(spec: str | None) -> float | None:
    if not spec:
        return None
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*", spec.lower())
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2) or "s"
    return val * {"s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0}[unit]


def encode_cwd_bucket(cwd: Path) -> str:
    real = cwd.resolve()
    try:
        rel = real.relative_to(home_dir().resolve())
        parts = "-".join(rel.parts)
        return f"-{parts}" if parts else "-"
    except ValueError:
        pass
    encoded = re.sub(r"[:\\/]+", "-", str(real)).strip("-")
    return f"--{encoded}--"


def read_session_header(path: Path) -> dict[str, Any]:
    title = ""
    session_obj: dict[str, Any] = {}
    try:
        with path.open("rb") as f:
            head = f.read(16384).decode("utf-8", errors="replace")
    except OSError:
        return {"id": path.stem.split("_", 1)[-1], "title": ""}
    for line in head.splitlines()[:10]:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "title":
            title = obj.get("title", "")
        elif obj.get("type") == "session":
            session_obj = obj
            break
    if not session_obj:
        stem = path.stem
        sid = stem.split("_", 1)[1] if "_" in stem else stem
        session_obj = {"id": sid}
    session_obj.setdefault("title", title)
    return session_obj


def get_collab_hosts(omp_bin: str) -> dict[str, dict[str, Any]]:
    proc = subprocess.run(
        [omp_bin, "collab", "list", "--json"],
        capture_output=True,
        text=True,
        check=False,
        **_subproc_no_window_kwargs(),
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    try:
        data = json.loads(proc.stdout)
        return {h["sessionId"]: h for h in data.get("hosts", []) if "sessionId" in h}
    except Exception:
        return {}


def check_leases(omp_bin: str, session_ids: list[str]) -> set[str]:
    if not session_ids:
        return set()
    proc = subprocess.run(
        [omp_bin, "session", "lease", "--json", "--", *session_ids],
        capture_output=True,
        text=True,
        check=False,
        **_subproc_no_window_kwargs(),
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return set()
    try:
        data = json.loads(proc.stdout)
        return set(data.get("held", []))
    except Exception:
        return set()


def resolve_session(target: str, cwd: Path, allow_missing: bool = False) -> Path | None:
    if target in ("new", "same"):
        return None

    p = Path(target).expanduser()
    if p.is_file():
        return p.resolve()

    sroot = sessions_root()
    bucket = sroot / encode_cwd_bucket(cwd)
    search_dirs = [bucket] if bucket.is_dir() else []
    if target != "latest" and sroot.is_dir():
        search_dirs.extend(d for d in sroot.iterdir() if d.is_dir() and d != bucket)

    if target == "latest":
        if not bucket.is_dir():
            if allow_missing:
                return None
            raise SystemExit(f"error: no session bucket at {bucket}")
        files = sorted(
            (f for f in bucket.glob("*.jsonl") if "__advisor" not in f.name),
            key=lambda f: f.stat().st_mtime,
            reverse=True,
        )
        if not files:
            if allow_missing:
                return None
            raise SystemExit(f"error: no .jsonl sessions in {bucket}")
        return files[0]

    matches: list[Path] = []
    for d in search_dirs:
        for f in d.glob("*.jsonl"):
            if "__advisor" in f.name:
                continue
            if target in f.name:
                matches.append(f)
    if not matches:
        raise SystemExit(f"error: could not resolve session {target!r}")
    matches.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    return matches[0]


def fmt_ts(ts: Any) -> str:
    if ts is None:
        return ""
    if isinstance(ts, (int, float)):
        if ts > 1e11:
            ts = ts / 1000.0
        return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds")
    return str(ts)


def extract_content(content: Any) -> tuple[str, list[str], int]:
    if isinstance(content, str):
        return content.strip(), [], 0
    if not isinstance(content, list):
        return str(content).strip(), [], 0
    texts: list[str] = []
    tools: list[str] = []
    thinking_chars = 0
    for item in content:
        if isinstance(item, str):
            texts.append(item)
        elif isinstance(item, dict):
            itype = item.get("type", "")
            if itype == "text":
                t = item.get("text", "").strip()
                if t:
                    texts.append(t)
            elif itype == "thinking":
                thinking_chars += len(item.get("thinking", ""))
            elif itype in ("toolCall", "tool_use"):
                name = item.get("name", itype)
                args = item.get("arguments") or item.get("input") or {}
                detail = ""
                if isinstance(args, dict):
                    for k in ("path", "command", "intent", "pattern"):
                        if k in args and isinstance(args[k], str):
                            detail = args[k].splitlines()[0][:60]
                            break
                tools.append(f"{name}({detail})" if detail else name)
    return "\n".join(texts), tools, thinking_chars


def _pick_unclaimed_omp_in_tab(
    agents: list[dict[str, Any]],
    pane_files: dict[int, str],
    cwd: Path | None,
) -> int | None:
    """Select an unbound `omp` pane (verified via `tern inspect`'s `omp_session_file`) in the caller's tab."""
    unclaimed = [
        a
        for a in agents
        if a.get("same_tab")
        and a.get("bound_owner") is None
        and int(a["pane"]) in pane_files
    ]
    if not unclaimed:
        return None
    if cwd is not None:
        want = cwd.resolve()
        for a in unclaimed:
            try:
                if Path(str(a.get("cwd", ""))).resolve() == want:
                    return int(a["pane"])
            except OSError:
                pass
    return int(unclaimed[0]["pane"])


def resolve_target_pane_from_status(
    status: dict[str, Any],
    inspect_data: dict[str, Any] | None,
    cwd: Path,
    target_session: str,
    session_path: Path | None,
    anchor_pane: int | None = None,
) -> tuple[int | None, bool]:
    """Return (target_pane_id, reset_new) from explicit ownership (`bound_pane`) + authoritative `omp_session_file`."""
    pane_files = extract_omp_pane_files(inspect_data)
    agents = [
        a
        for a in status.get("agents", [])
        if not a.get("is_self") and (anchor_pane is None or int(a["pane"]) != anchor_pane)
    ]
    active_ids = {int(a["pane"]) for a in agents}

    raw_bound = status.get("bound_pane")
    bound_pane: int | None = None
    if raw_bound is not None:
        bp = int(raw_bound)
        if (anchor_pane is None or bp != anchor_pane) and bp in active_ids:
            bound_pane = bp

    if session_path is not None:
        want = str(session_path.resolve())
        for a in agents:
            pid = int(a["pane"])
            if pane_files.get(pid) == want:
                return pid, False
        return None, False

    if target_session == "same":
        if bound_pane is not None:
            return bound_pane, False
        adopted = _pick_unclaimed_omp_in_tab(agents, pane_files, cwd)
        return (adopted, False) if adopted is not None else (None, False)

    if target_session == "new":
        if bound_pane is not None:
            return bound_pane, True
        return None, False

    return None, False


def select_wingman_pane_from_status(
    status: dict[str, Any],
    inspect_data: dict[str, Any] | None,
    my_pane: int,
    cwd: Path | None = None,
) -> int:
    """Resolve the caller's wingman pane for lifecycle/layout ops (`interrupt`, `stop`, `pip`, `dock`, `transcript`)."""
    raw_bound = status.get("bound_pane")
    if raw_bound is not None and int(raw_bound) != my_pane:
        return int(raw_bound)

    pane_files = extract_omp_pane_files(inspect_data)
    agents = [
        a
        for a in status.get("agents", [])
        if not a.get("is_self") and int(a["pane"]) != my_pane
    ]
    adopted = _pick_unclaimed_omp_in_tab(agents, pane_files, cwd)
    if adopted is not None:
        return adopted

    raise SystemExit(
        "error: no wingman pane is bound to this pane or open in this tab "
        "(pass an explicit `<pane>` id from `wingman.py info` to target another pane)"
    )


def select_owner_pane_from_status(
    status: dict[str, Any],
    my_pane: int,
) -> int:
    """Resolve the caller wingman's supervisor/owner pane (`boundOwner`) for reverse reporting."""
    agents = [
        a
        for a in status.get("agents", [])
        if not a.get("is_self") and int(a["pane"]) != my_pane
    ]
    active_ids = {int(a["pane"]) for a in agents}

    raw_owner = status.get("owner_pane")
    if raw_owner is not None:
        oid = int(raw_owner)
        if oid != my_pane and oid in active_ids:
            return oid

    for a in status.get("agents", []):
        if int(a["pane"]) == my_pane and a.get("bound_owner") is not None:
            oid = int(a["bound_owner"])
            if oid != my_pane and oid in active_ids:
                return oid

    same_tab_peers = [int(a["pane"]) for a in agents if a.get("same_tab")]
    if len(same_tab_peers) == 1:
        return same_tab_peers[0]

    raise SystemExit(
        "error: no supervisor/owner pane is bound to this pane "
        "(pass `--pane <id>` from `wingman.py info` to specify the target owner pane)"
    )


def is_caller_acp_agent(
    status: dict[str, Any],
    inspect_data: dict[str, Any] | None,
    my_pane: int,
) -> bool:
    """True when `my_pane` is a Tern ACP chat pane (e.g. `agy`, `claude`, `codex`) rather than a plain shell or `omp`."""
    pane_files = extract_omp_pane_files(inspect_data)
    if my_pane in pane_files:
        return False
    return any(int(a["pane"]) == my_pane for a in status.get("agents", []))


def cmd_info(args: argparse.Namespace) -> None:
    omp_bin = find_omp_bin()
    tern_bin = find_tern_bin()
    ovnfs_bin = find_ovnfs_bin()
    my_pane = current_tern_pane()
    cwd = Path(args.cwd).resolve()
    bucket = sessions_root() / encode_cwd_bucket(cwd)
    hosts = get_collab_hosts(omp_bin)

    bridge_status: dict[str, Any] | None = None
    if my_pane is not None:
        try:
            bridge_status = call_bridge({"op": "status", "anchor_pane": my_pane}, timeout=DEFAULT_BRIDGE_TIMEOUT)
        except Exception:
            bridge_status = None

    inspect_data = inspect_tern(tern_bin) if my_pane else None
    pane_files = extract_omp_pane_files(inspect_data)

    sessions_out = []
    if bucket.is_dir():
        files = sorted(
            (f for f in bucket.glob("*.jsonl") if "__advisor" not in f.name),
            key=lambda f: f.stat().st_mtime,
            reverse=True,
        )[: args.limit]
        headers = [(f, read_session_header(f)) for f in files]
        sids = [h["id"] for _, h in headers if "id" in h]
        held = check_leases(omp_bin, sids)
        for f, h in headers:
            sid = h.get("id", "")
            st = f.stat()
            host = hosts.get(sid)
            sessions_out.append(
                {
                    "sessionId": sid,
                    "path": str(f),
                    "sizeMB": round(st.st_size / (1024 * 1024), 2),
                    "mtime": fmt_ts(st.st_mtime),
                    "title": h.get("title", ""),
                    "leaseHeld": sid in held,
                    "hostPid": host.get("pid") if host else None,
                    "busy": host.get("busy") if host else None,
                }
            )

    agents_out = []
    if bridge_status and bridge_status.get("ok"):
        for a in bridge_status.get("agents", []):
            pid = int(a["pane"])
            lm = a.get("last_message") or ""
            agents_out.append(
                {
                    "pane": pid,
                    "isSelf": bool(a.get("is_self") or (my_pane is not None and pid == my_pane)),
                    "isBoundToMe": bool(a.get("is_bound_to_me")),
                    "boundOwner": a.get("bound_owner"),
                    "autoCallback": a.get("auto_callback"),
                    "queuedCount": int(a.get("queued_count") or 0),
                    "queuedPreview": a.get("queued_preview"),
                    "queuedCallbacksCount": int(a.get("queued_callbacks_count") or 0),
                    "sameTab": a.get("same_tab"),
                    "state": a.get("state"),
                    "model": a.get("model"),
                    "cwd": a.get("cwd"),
                    "sessionFile": pane_files.get(pid),
                    "lastMessagePreview": lm[:200] + ("…" if len(lm) > 200 else ""),
                }
            )

    out = {
        "ompBin": omp_bin,
        "ovnfsBin": ovnfs_bin,
        "ternPane": my_pane,
        "boundWingmanPane": bridge_status.get("bound_pane") if bridge_status else None,
        "ownerPane": bridge_status.get("owner_pane") if bridge_status else None,
        "autoCallback": bridge_status.get("auto_callback") if bridge_status else None,
        "wingmanBridgeReady": bool(bridge_status and bridge_status.get("ok")),
        "floats": bridge_status.get("floats", []) if bridge_status else [],
        "ternAgents": agents_out,
        "cwd": str(cwd),
        "sessions": sessions_out,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def cmd_send(args: argparse.Namespace) -> None:
    """Deliver prompt via native Tern TSP `cx.agents` (`wingman` plugin) or headless `-p` fallback."""
    omp_bin = find_omp_bin()
    tern_bin = find_tern_bin()
    my_pane = current_tern_pane()
    cwd = Path(args.cwd).resolve()

    prompt = args.prompt
    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    if not prompt or not prompt.strip():
        raise SystemExit("error: prompt is empty")
    prompt = prompt.strip()

    session_path = resolve_session(args.session, cwd, allow_missing=True)
    timeout_s = parse_duration_seconds(args.max_time)
    use_tui = args.mode == "tui" or (args.mode == "auto" and my_pane is not None)

    if use_tui:
        if my_pane is None:
            raise SystemExit("error: --mode tui requested, but $TERN_PANE is not set")
        try:
            status = call_bridge({"op": "status", "anchor_pane": my_pane}, timeout=DEFAULT_BRIDGE_TIMEOUT)
        except Exception as exc:
            raise SystemExit(
                f"error: Tern `wingman` plugin did not answer ({exc}). "
                "Install it with `tern plugin install github.com/ninthcj/tern-wingman` or pass `--mode headless`."
            )

        inspect_data = inspect_tern(tern_bin)
        target_pane, reset_new = resolve_target_pane_from_status(
            status, inspect_data, cwd, args.session, session_path, anchor_pane=my_pane
        )
        use_async_cb = (args.delivery == "async") or (
            args.delivery == "auto" and is_caller_acp_agent(status, inspect_data, my_pane)
        )

        if args.session == "same" and target_pane is None:
            raise SystemExit(
                "error: `same` requested, but no wingman pane is bound to this pane or open in this tab. "
                "Choose `new` for a fresh session, or pass `latest` / an explicit `<sessionId>` from `info`."
            )

        if target_pane is None and session_path is not None:
            sid = read_session_header(session_path).get("id", "")
            if sid and sid in check_leases(omp_bin, [sid]):
                host = get_collab_hosts(omp_bin).get(sid)
                if host and host.get("busy"):
                    raise SystemExit(f"error: session {sid} is BUSY (pid={host.get('pid')})")
                if args.takeover_idle and host and host.get("pid") and not host.get("busy"):
                    os.kill(int(host["pid"]), signal.SIGTERM)
                    for _ in range(15):
                        time.sleep(0.3)
                        if sid not in check_leases(omp_bin, [sid]):
                            break
                if sid in check_leases(omp_bin, [sid]):
                    raise SystemExit(
                        f"error: session {sid} lease is held externally (host={host}). "
                        "Pass --takeover-idle or use `new`."
                    )

        cmd_parts = [omp_bin, "--auto-approve", "--cwd", str(cwd)]
        if (target_pane is None or reset_new) and session_path is not None:
            cmd_parts += ["-r", str(session_path)]
        if args.model:
            cmd_parts += ["--model", args.model]
        if args.thinking:
            cmd_parts += ["--thinking", args.thinking]

        req: dict[str, Any] = {
            "op": "dispatch",
            "anchor_pane": my_pane,
            "target_pane": target_pane,
            "reset_new": reset_new,
            "queue": not args.no_queue,
            "async_callback": use_async_cb,
            "cwd": str(cwd),
            "command": format_command_line(cmd_parts),
            "prompt": prompt,
            "pip_corner": args.pip,
        }
        if args.auto_callback is not None:
            req["auto_callback"] = bool(args.auto_callback)

        def _on_ack(frame: dict[str, Any]) -> None:
            pane_id = int(frame["pane"])
            if frame.get("queued"):
                pos = frame.get("position", 1)
                print(
                    f"[wingman] Native TSP queued (#{pos}, {len(prompt)} chars) -> pane {pane_id} (waiting on agent_finished)",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                print(
                    f"[wingman] Native TSP dispatch ({len(prompt)} chars) -> pane {pane_id}",
                    file=sys.stderr,
                    flush=True,
                )

        try:
            reply = call_bridge(req, timeout=DEFAULT_BRIDGE_TIMEOUT if use_async_cb else timeout_s, on_ack=_on_ack)
        except TimeoutError:
            print(f"[wingman] Timed out after {args.max_time or DEFAULT_BRIDGE_TIMEOUT} waiting for wingman bridge.", file=sys.stderr)
            raise SystemExit(124)

        if not reply.get("ok"):
            st = reply.get("status", "failed")
            err = reply.get("error") or st
            print(f"[wingman] Worker finished with status={st}: {err}", file=sys.stderr)
            if reply.get("last_message"):
                print(reply["last_message"])
            raise SystemExit(2 if st == "waiting_input" else 1)

        if reply.get("async_callback"):
            dispatched_pane = int(reply["pane"])
            if reply.get("queued"):
                pos = int(reply.get("position") or 1)
                print(
                    f"[wingman] Queued (#{pos}, {len(prompt)} chars) onto wingman pane {dispatched_pane} (async ACP callback armed).\n"
                    f"When pane {dispatched_pane} finishes this turn, Tern will automatically submit `[Wingman auto-callback · pane {dispatched_pane}]` "
                    "into your chat composer as a visible turn. Do NOT poll or sleep; end your turn now and wait for the callback."
                )
            else:
                print(
                    f"[wingman] Dispatched ({len(prompt)} chars) onto wingman pane {dispatched_pane} (async ACP callback armed).\n"
                    f"When pane {dispatched_pane} finishes, Tern will automatically submit `[Wingman auto-callback · pane {dispatched_pane}]` "
                    "into your chat composer as a visible turn. Do NOT poll or sleep; end your turn now and wait for the callback."
                )
            raise SystemExit(0)

        if reply.get("last_message"):
            print(reply["last_message"])
        raise SystemExit(0)

    # Headless fallback outside Tern (-p --wait-async --auto-approve)
    if args.session == "same":
        raise SystemExit(
            "error: `same` refers to an active Tern pane; in headless mode choose `new`, `latest`, or an explicit `<sessionId>`."
        )

    sid = read_session_header(session_path).get("id", "") if session_path else ""
    if sid and sid in check_leases(omp_bin, [sid]) and not args.allow_fork:
        host = get_collab_hosts(omp_bin).get(sid)
        if args.takeover_idle and host and host.get("pid") and not host.get("busy"):
            os.kill(int(host["pid"]), signal.SIGTERM)
            for _ in range(15):
                time.sleep(0.3)
                if sid not in check_leases(omp_bin, [sid]):
                    break
        if sid in check_leases(omp_bin, [sid]):
            raise SystemExit(f"error: session {sid} lease is held (host={host}).")

    cmd = [omp_bin, "-p", "--wait-async", "--auto-approve", "--no-title", "--cwd", str(cwd)]
    if session_path is not None:
        cmd += ["-r", str(session_path)]
    if args.model:
        cmd += ["--model", args.model]
    if args.thinking:
        cmd += ["--thinking", args.thinking]
    if args.max_time:
        cmd += ["--max-time", args.max_time]
    cmd += ["--", prompt]

    popen_kwargs: dict[str, Any] = {}
    if IS_WINDOWS:
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if flags:
            popen_kwargs["creationflags"] = flags
    else:
        popen_kwargs["start_new_session"] = True

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **popen_kwargs)
    stdout, stderr = proc.communicate()
    if stderr:
        print(stderr, file=sys.stderr, end="")
    if stdout:
        print(stdout, end="")
    raise SystemExit(proc.returncode)


def resolve_same_tab_agent_pane(my_pane: int, cwd: Path | None = None) -> int:
    status = call_bridge({"op": "status", "anchor_pane": my_pane}, timeout=DEFAULT_BRIDGE_TIMEOUT)
    inspect_data = None
    if status.get("bound_pane") is None:
        inspect_data = inspect_tern(find_tern_bin())
    return select_wingman_pane_from_status(status, inspect_data, my_pane, cwd=cwd)


def _resolve_explicit_or_bound_pane(args: argparse.Namespace, my_pane: int) -> int:
    if args.pane and args.pane.isdigit():
        pane = int(args.pane)
        if pane == my_pane:
            raise SystemExit(f"error: refusing to target caller's own pane ({my_pane})")
        return pane
    cwd = Path(args.cwd).resolve() if getattr(args, "cwd", None) else None
    return resolve_same_tab_agent_pane(my_pane, cwd=cwd)


def cmd_transcript(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `transcript` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {"op": "transcript", "anchor_pane": my_pane, "target_pane": pane, "last": args.last},
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(json.dumps(reply.get("messages", []), ensure_ascii=False, indent=2))


def cmd_pip(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `pip` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {"op": "pip", "anchor_pane": my_pane, "target_pane": pane, "corner": args.corner},
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(json.dumps({"pane": pane, "floating": args.corner}, indent=2))


def cmd_dock(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `dock` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {"op": "dock", "anchor_pane": my_pane, "target_pane": pane, "dir": args.dir},
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(json.dumps({"pane": pane, "docked": args.dir}, indent=2))


def cmd_interrupt(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `interrupt` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {"op": "interrupt", "anchor_pane": my_pane, "target_pane": pane},
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(json.dumps({"pane": pane, "interrupted": True}, indent=2))


def cmd_unqueue(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `unqueue` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {
            "op": "unqueue",
            "anchor_pane": my_pane,
            "target_pane": pane,
            "position": args.position,
        },
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(
        json.dumps(
            {
                "pane": pane,
                "cancelled": reply.get("cancelled", 0),
                "remaining": reply.get("remaining", 0),
            },
            indent=2,
        )
    )


def cmd_stop(args: argparse.Namespace) -> None:
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `stop` requires running inside Tern")
    pane = _resolve_explicit_or_bound_pane(args, my_pane)
    reply = call_bridge(
        {"op": "stop", "anchor_pane": my_pane, "target_pane": pane},
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(json.dumps({"pane": pane, "stopped": True}, indent=2))


def cmd_report(args: argparse.Namespace) -> None:
    """Push a report/progress/question from a wingman pane back up to its bound supervisor (`boundOwner`)."""
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `report` requires running inside Tern")

    prompt = args.prompt
    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    if not prompt or not prompt.strip():
        raise SystemExit("error: report prompt is empty")
    prompt = prompt.strip()

    explicit_owner: int | None = None
    if args.pane:
        if not str(args.pane).isdigit():
            raise SystemExit(f"error: invalid owner pane id: {args.pane!r}")
        explicit_owner = int(args.pane)
        if explicit_owner == my_pane:
            raise SystemExit(f"error: refusing to report onto caller's own pane ({my_pane})")
    else:
        status = call_bridge({"op": "status", "anchor_pane": my_pane}, timeout=DEFAULT_BRIDGE_TIMEOUT)
        explicit_owner = select_owner_pane_from_status(status, my_pane)

    reply = call_bridge(
        {
            "op": "report",
            "anchor_pane": my_pane,
            "target_pane": explicit_owner,
            "kind": args.kind,
            "prompt": prompt,
        },
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(
        json.dumps(
            {
                "workerPane": reply.get("worker_pane", my_pane),
                "ownerPane": reply.get("owner_pane", explicit_owner),
                "kind": reply.get("kind", args.kind),
                "delivered": bool(reply.get("delivered")),
                "queued": bool(reply.get("queued")),
                "position": int(reply.get("position") or 0),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def cmd_callback(args: argparse.Namespace) -> None:
    """Inspect or toggle unsolicited wingman -> supervisor auto-callback policy."""
    my_pane = current_tern_pane()
    if my_pane is None:
        raise SystemExit("error: `callback` requires running inside Tern")
    owner_pane: int | None = int(args.pane) if (args.pane and str(args.pane).isdigit()) else None
    reply = call_bridge(
        {
            "op": "callback",
            "anchor_pane": my_pane,
            "owner_pane": owner_pane,
            "mode": args.mode,
            "scope": "global" if args.global_scope else "owner",
        },
        timeout=DEFAULT_BRIDGE_TIMEOUT,
    )
    if not reply.get("ok"):
        raise SystemExit(f"error: {reply.get('error')}")
    print(
        json.dumps(
            {
                "ownerPane": reply.get("owner_pane"),
                "autoCallback": bool(reply.get("enabled")),
                "defaultAutoCallback": bool(reply.get("default_enabled")),
            },
            indent=2,
        )
    )


def cmd_peek(args: argparse.Namespace) -> None:
    """O(1) tail seek on .jsonl for granular mid-turn TOOL_START / TOOL_RESULT inspection."""
    cwd = Path(args.cwd).resolve()
    target = "latest" if args.session == "same" else args.session
    path = resolve_session(target, cwd, allow_missing=False)
    assert path is not None
    omp_bin = find_omp_bin()
    header = read_session_header(path)
    sid = header.get("id", "")
    held = sid in check_leases(omp_bin, [sid]) if sid else False
    host = get_collab_hosts(omp_bin).get(sid)

    size = path.stat().st_size
    read_bytes = min(size, args.bytes)
    with path.open("rb") as f:
        f.seek(size - read_bytes)
        chunk = f.read(read_bytes).decode("utf-8", errors="replace")

    raw_lines = chunk.splitlines()
    if read_bytes < size and raw_lines:
        raw_lines = raw_lines[1:]

    events: list[str] = []
    for raw in raw_lines[-args.lines :]:
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        etype = obj.get("type", "")
        ts = fmt_ts(obj.get("timestamp"))
        if etype == "message":
            msg = obj.get("message", {})
            role = msg.get("role", "")
            if role in ("user", "assistant"):
                text, tools, think_len = extract_content(msg.get("content", ""))
                parts = []
                if think_len:
                    parts.append(f"thinking={think_len}c")
                if tools:
                    parts.append(f"tools={tools}")
                if text:
                    preview = text.replace("\n", " ⏎ ")[:240]
                    parts.append(f"text={preview!r}")
                events.append(f"[{ts}] {role.upper()}: " + " | ".join(parts))
            elif role == "toolResult":
                tname = msg.get("toolName", "tool")
                is_err = msg.get("isError", False)
                text, _, _ = extract_content(msg.get("content", ""))
                preview = text.replace("\n", " ⏎ ")[:140]
                events.append(f"[{ts}] TOOL_RESULT({tname}{', ERROR' if is_err else ''}): {preview!r}")
        elif etype == "custom":
            ctype = obj.get("customType", "")
            data = obj.get("data", {})
            if ctype == "tool_execution_start":
                events.append(
                    f"[{ts}] TOOL_START: {data.get('toolName')} — {data.get('intent') or str(data.get('args', ''))[:100]}"
                )
            elif ctype == "session_exit":
                events.append(f"[{ts}] SESSION_EXIT: {data}")

    print(f"Session: {path} ({round(size / (1024 * 1024), 2)} MB)")
    print(f"ID: {sid} | LeaseHeld: {held} | CollabHost: {host['pid'] if host else None} (busy={host['busy'] if host else 'n/a'})")
    print("--- Tail Activity ---")
    for ev in events:
        print(ev)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Wingman: Native Tern TSP (`WindowCx.agents`) & headless worker bridge.")
    sub = p.add_subparsers(dest="subcmd", required=True)

    p_info = sub.add_parser("info", help="List live Tern TSP agents, ownership bindings, PiP floats, and recent sessions")
    p_info.add_argument("--cwd", default=".", help="Workspace directory")
    p_info.add_argument("--limit", type=int, default=6, help="Max recent sessions to list")
    p_info.set_defaults(func=cmd_info)

    p_send = sub.add_parser("send", help="Atomic TSP dispatch (`cx.agents:start/ask`) + event-driven wait")
    p_send.add_argument("session", help="Explicit target: 'new', 'same', or <sessionId/path>")
    grp = p_send.add_mutually_exclusive_group(required=True)
    grp.add_argument("--prompt", help="Prompt text")
    grp.add_argument("--prompt-file", help="Path to prompt file")
    p_send.add_argument("--cwd", default=".", help="Workspace directory")
    p_send.add_argument("--pip", choices=["tl", "tr", "bl", "br"], help="Float worker as Picture-in-Picture corner")
    p_send.add_argument("--mode", choices=["auto", "tui", "headless"], default="auto")
    p_send.add_argument("--model", help="Optional model override")
    p_send.add_argument("--thinking", help="Optional thinking level")
    p_send.add_argument("--max-time", help="Optional max runtime (e.g. 30m, 1h)")
    p_send.add_argument("--takeover-idle", action="store_true")
    p_send.add_argument("--allow-fork", action="store_true")
    p_send.add_argument("--no-queue", action="store_true", help="Fail immediately if target wingman pane is busy instead of queueing natively")
    deliv_grp = p_send.add_mutually_exclusive_group()
    deliv_grp.add_argument("--async", dest="delivery", action="store_const", const="async", default="auto", help="Return immediately after TSP dispatch and deliver reply via `cx.agents:ask` callback (default for Tern ACP callers)")
    deliv_grp.add_argument("--wait", dest="delivery", action="store_const", const="wait", help="Block synchronously until wingman turn finishes (default for shell/non-ACP callers)")
    cb_grp = p_send.add_mutually_exclusive_group()
    cb_grp.add_argument("--auto-callback", dest="auto_callback", action="store_true", default=None, help="Enable unsolicited worker->owner auto-callback (default: on)")
    cb_grp.add_argument("--no-auto-callback", dest="auto_callback", action="store_false", help="Disable unsolicited worker->owner auto-callback for this binding")
    p_send.set_defaults(func=cmd_send)

    p_rep = sub.add_parser("report", help="Push a report/progress/question from a wingman pane back up to its bound supervisor")
    rep_grp = p_rep.add_mutually_exclusive_group(required=True)
    rep_grp.add_argument("--prompt", "--message", "-m", dest="prompt", help="Report message text")
    rep_grp.add_argument("--prompt-file", help="Path to report markdown/text file")
    p_rep.add_argument("--kind", choices=["final", "progress", "question"], default="final", help="Report kind (`progress` keeps end-of-turn auto-callback active)")
    p_rep.add_argument("--pane", help="Optional explicit supervisor/owner pane id (defaults to caller's boundOwner)")
    p_rep.set_defaults(func=cmd_report)

    p_cb = sub.add_parser("callback", help="Inspect or toggle unsolicited wingman -> supervisor auto-callback")
    p_cb.add_argument("mode", nargs="?", choices=["status", "on", "off", "reset"], default="status")
    p_cb.add_argument("--global", dest="global_scope", action="store_true", help="Apply to global default instead of current owner binding")
    p_cb.add_argument("--pane", help="Optional owner pane id")
    p_cb.set_defaults(func=cmd_callback)

    p_tr = sub.add_parser("transcript", help="Read structured TSP chat messages from memory (`cx.agents:transcript`)")
    p_tr.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_tr.add_argument("--last", type=int, default=8, help="Number of recent messages")
    p_tr.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_tr.set_defaults(func=cmd_transcript)

    p_pip = sub.add_parser("pip", help="Float worker pane into Picture-in-Picture corner")
    p_pip.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_pip.add_argument("--corner", choices=["tl", "tr", "bl", "br"], default="br")
    p_pip.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_pip.set_defaults(func=cmd_pip)

    p_dock = sub.add_parser("dock", help="Dock floating Picture-in-Picture worker back into split")
    p_dock.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_dock.add_argument("--dir", choices=["left", "right", "up", "down"], default="right")
    p_dock.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_dock.set_defaults(func=cmd_dock)

    p_int = sub.add_parser("interrupt", help="Interrupt active turn via `cx.agents:interrupt`")
    p_int.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_int.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_int.set_defaults(func=cmd_interrupt)

    p_unq = sub.add_parser("unqueue", help="Cancel queued (not-yet-sent) prompts waiting on a busy wingman pane")
    p_unq.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_unq.add_argument("--position", type=int, help="Optional 1-based queue slot to cancel (default: cancel all)")
    p_unq.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_unq.set_defaults(func=cmd_unqueue)

    p_stop = sub.add_parser("stop", help="Close worker pane and terminate process via `cx.agents:stop`")
    p_stop.add_argument("pane", nargs="?", help="Agent pane id (defaults to caller's bound wingman)")
    p_stop.add_argument("--cwd", help="Optional workspace directory to disambiguate unbound worker pane")
    p_stop.set_defaults(func=cmd_stop)

    p_peek = sub.add_parser("peek", help="O(1) .jsonl tail seek for granular mid-turn tool calls")
    p_peek.add_argument("session", nargs="?", default="latest")
    p_peek.add_argument("--cwd", default=".")
    p_peek.add_argument("--bytes", type=int, default=65536)
    p_peek.add_argument("--lines", type=int, default=25)
    p_peek.set_defaults(func=cmd_peek)

    return p


if __name__ == "__main__":
    parser = build_parser()
    ns = parser.parse_args()
    ns.func(ns)
