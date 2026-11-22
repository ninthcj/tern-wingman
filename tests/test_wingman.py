from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
MUX_PATH = ROOT_DIR / "mux.py"
SCRIPT_PATH = ROOT_DIR / "skills" / "wingman" / "scripts" / "wingman.py"

spec = importlib.util.spec_from_file_location("wingman", SCRIPT_PATH)
assert spec and spec.loader
wingman = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wingman)


class WingmanTests(unittest.TestCase):
    def test_parse_duration_seconds(self) -> None:
        self.assertIsNone(wingman.parse_duration_seconds(None))
        self.assertEqual(wingman.parse_duration_seconds("45"), 45.0)
        self.assertEqual(wingman.parse_duration_seconds("1.5m"), 90.0)
        self.assertEqual(wingman.parse_duration_seconds("2h"), 7200.0)

    def test_encode_cwd_bucket(self) -> None:
        home = Path.home().resolve()
        self.assertEqual(wingman.encode_cwd_bucket(home), "-")
        self.assertEqual(wingman.encode_cwd_bucket(home / "Code" / "demo"), "-Code-demo")
        self.assertEqual(wingman.encode_cwd_bucket(Path("/opt/work/repo")), "--opt-work-repo--")

    def test_explicit_ownership_works_across_ovnfs_and_subdirs(self) -> None:
        lead_cwd = Path("/tmp/main-repo")
        ovnfs_cwd = Path("/tmp/ovnfs-checkout-99")
        status = {
            "bound_pane": 105,
            "agents": [
                {"pane": 100, "is_self": True, "same_tab": True, "cwd": str(lead_cwd), "state": "working"},
                {
                    "pane": 105,
                    "is_self": False,
                    "is_bound_to_me": True,
                    "bound_owner": 100,
                    "same_tab": True,
                    "cwd": str(ovnfs_cwd),
                    "state": "idle",
                },
            ],
        }
        # Even though bound pane 105 has a different cwd (ovnfs checkout), `same` & `interrupt` target 105;
        # plain `new` always spawns an additional worker (no target) and only `--replace` resets 105.
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, lead_cwd, "same", None, anchor_pane=100),
            (105, False),
        )
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, lead_cwd, "new", None, anchor_pane=100),
            (None, False),
        )
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, lead_cwd, "new", None, anchor_pane=100, replace=True),
            (105, True),
        )
        self.assertEqual(wingman.select_wingman_pane_from_status(status, None, 100, cwd=lead_cwd), 105)

    def test_unbound_adoption_uses_authoritative_omp_session_file_and_respects_other_owners(self) -> None:
        cwd = Path("/tmp/demo-repo")
        inspect_data = {
            "panes": [
                {"pane": 100, "omp_session_file": None},  # ACP agy lead 1
                {"pane": 200, "omp_session_file": None},  # ACP claude lead 2 in same tab
                {"pane": 201, "omp_session_file": "/tmp/s201.jsonl"},  # Owned by lead 200
                {"pane": 102, "omp_session_file": "/tmp/s102.jsonl"},  # Unclaimed omp pane
            ]
        }
        status = {
            "bound_pane": None,
            "agents": [
                {"pane": 100, "is_self": True, "same_tab": True, "cwd": str(cwd), "state": "working"},
                {"pane": 200, "is_self": False, "same_tab": True, "cwd": str(cwd), "state": "working"},
                {"pane": 201, "is_self": False, "bound_owner": 200, "same_tab": True, "cwd": str(cwd), "state": "idle"},
                {"pane": 102, "is_self": False, "bound_owner": None, "same_tab": True, "cwd": str(cwd), "state": "idle"},
            ],
        }
        # Adopts unclaimed omp pane 102 — never self (100), never ACP peer (200), never peer's wingman (201)
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, inspect_data, cwd, "same", None, anchor_pane=100),
            (102, False),
        )
        self.assertEqual(wingman.select_wingman_pane_from_status(status, inspect_data, 100, cwd=cwd), 102)

        # `new` when caller has no bound_pane spawns a fresh split (None, False) without killing manual pane 102
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, inspect_data, cwd, "new", None, anchor_pane=100),
            (None, False),
        )

        # When only ACP panes exist in the tab (no omp_session_file), refuses to hit self or ACP peer
        only_acp = {
            "bound_pane": None,
            "agents": [
                {"pane": 100, "is_self": True, "same_tab": True, "cwd": str(cwd), "state": "working"},
                {"pane": 200, "is_self": False, "same_tab": True, "cwd": str(cwd), "state": "idle"},
            ],
        }
        with self.assertRaises(SystemExit):
            wingman.select_wingman_pane_from_status(only_acp, inspect_data, 100, cwd=cwd)

    def test_cli_control_subcommands_accept_cwd(self) -> None:
        import io
        from unittest import mock

        parser = wingman.build_parser()
        for sub in ("interrupt", "unqueue", "stop", "pip", "dock", "transcript", "surface", "retry"):
            ns = parser.parse_args([sub, "--cwd", "/tmp/demo-repo", "--pane", "321"])
            self.assertEqual(ns.cwd, "/tmp/demo-repo")
            self.assertEqual(ns.pane_flag, "321")
        ns_unq = parser.parse_args(["unqueue", "--position", "2"])
        self.assertEqual(ns_unq.position, 2)
        ns_send = parser.parse_args(["send", "same", "-m", "hi", "--no-queue"])
        self.assertEqual(ns_send.prompt, "hi")
        self.assertTrue(ns_send.no_queue)
        self.assertEqual(ns_send.delivery, "auto")
        self.assertEqual(parser.parse_args(["send", "same", "--message", "hi", "--async"]).delivery, "async")
        self.assertEqual(parser.parse_args(["send", "same", "--prompt", "hi", "--wait"]).delivery, "wait")
        self.assertIsNone(ns_send.auto_callback)
        ns_send_cb_off = parser.parse_args(["send", "same", "--prompt", "hi", "--no-auto-callback"])
        self.assertFalse(ns_send_cb_off.auto_callback)
        ns_send_cb_on = parser.parse_args(["send", "same", "--prompt", "hi", "--auto-callback"])
        self.assertTrue(ns_send_cb_on.auto_callback)
        with mock.patch.object(wingman.sys, "stdin", io.StringIO("  from stdin  \n")):
            self.assertEqual(wingman._read_prompt_input(None, "-"), "from stdin")
        ns_rep = parser.parse_args(["report", "-m", "done!", "--kind", "progress", "--pane", "100"])
        self.assertEqual(ns_rep.prompt, "done!")
        self.assertEqual(ns_rep.kind, "progress")
        self.assertEqual(ns_rep.pane, "100")
        ns_cb = parser.parse_args(["callback", "off", "--global"])
        self.assertEqual(ns_cb.mode, "off")
        self.assertTrue(ns_cb.global_scope)

    def test_surface_cli_builds_auto_root_request(self) -> None:
        from unittest import mock

        parser = wingman.build_parser()
        calls: list[dict] = []

        def fake_bridge(req, timeout=None):
            calls.append(req)
            return {"ok": True, "root": "n7", "interactive_role": "omp.ask.card", "surface": "Pick one"}

        with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(wingman, "call_bridge", fake_bridge):
            with mock.patch("sys.stdout"):
                ns = parser.parse_args(["surface", "--pane", "200"])
                ns.func(ns)
                ns = parser.parse_args(["surface", "200", "--all", "--json", "--root", "x1"])
                ns.func(ns)
        self.assertEqual(calls[0], {"op": "surface", "anchor_pane": 100, "target_pane": 200, "as": "text", "auto_root": True})
        self.assertEqual(calls[1]["as"], "table")
        self.assertFalse(calls[1]["auto_root"])
        self.assertEqual(calls[1]["root"], "x1")
        with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), self.assertRaises(SystemExit):
            ns = parser.parse_args(["surface", "100"])
            ns.func(ns)

    def test_event_cli_parses_events_and_rearm(self) -> None:
        from unittest import mock

        parser = wingman.build_parser()
        calls: list[dict] = []
        replies = [{"ok": True, "results": []}, {"ok": False, "error": "boom"}]

        def fake_bridge(req, timeout=None):
            calls.append(req)
            return replies[len(calls) - 1]

        a = '{"ev":"action","id":"n1","act":"pick:0:0"}'
        b = '{"ev":"action","id":"n2","act":"submit"}'
        with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(wingman, "call_bridge", fake_bridge):
            with mock.patch("sys.stdout"):
                ns = parser.parse_args(["event", "--pane", "200", a, b])
                ns.func(ns)
                ns = parser.parse_args(["event", "--pane", "200", "--no-rearm", b])
                with self.assertRaises(SystemExit):
                    ns.func(ns)
            with self.assertRaises(SystemExit):
                ns = parser.parse_args(["event", "--pane", "200", "not-json"])
                ns.func(ns)
        self.assertEqual(calls[0]["op"], "event")
        self.assertEqual(calls[0]["target_pane"], 200)
        self.assertEqual(calls[0]["events"], [json.loads(a), json.loads(b)])
        self.assertTrue(calls[0]["rearm"])
        self.assertFalse(calls[1]["rearm"])
        self.assertEqual(len(calls), 2)

    def test_retry_cli_async_for_acp_and_wait_for_shell(self) -> None:
        from unittest import mock

        parser = wingman.build_parser()
        calls: list[dict] = []
        acp_status = {"agents": [{"pane": 100}, {"pane": 200}]}

        def fake_bridge(req, timeout=None, on_ack=None):
            calls.append({**req, "_timeout": timeout})
            if req["op"] == "status":
                return acp_status
            if req["async_callback"]:
                return {"ok": True, "async_callback": True, "pane": 200, "retried": True}
            if on_ack:
                on_ack({"_ack": True, "pane": 200})
            return {"ok": True, "pane": 200, "status": "done", "last_message": "fixed"}

        with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(
            wingman, "call_bridge", fake_bridge
        ), mock.patch.object(wingman, "inspect_tern", lambda _b: None), mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            # ACP caller (pane 100 is an agent) -> auto async
            ns = parser.parse_args(["retry", "--pane", "200"])
            with self.assertRaises(SystemExit) as cm:
                ns.func(ns)
            self.assertEqual(cm.exception.code, 0)
            # Shell caller -> auto wait (blocks with --max-time)
            acp_status = {"agents": [{"pane": 200}]}
            ns = parser.parse_args(["retry", "200", "--max-time", "2m"])
            ns.func(ns)
            # Explicit --wait skips status lookup
            ns = parser.parse_args(["retry", "--pane", "200", "--wait"])
            ns.func(ns)

        retries = [c for c in calls if c["op"] == "retry"]
        self.assertEqual([c["target_pane"] for c in retries], [200, 200, 200])
        self.assertEqual([c["async_callback"] for c in retries], [True, False, False])
        self.assertEqual(retries[1]["_timeout"], 120.0)
        self.assertEqual(sum(1 for c in calls if c["op"] == "status"), 2)

    def test_select_owner_pane_from_status_reverse_lookup(self) -> None:
        # 1. Explicit `owner_pane` from bindings_v1 works even across ovnfs checkouts & multiple agents in tab
        status_bound = {
            "owner_pane": 100,
            "agents": [
                {"pane": 100, "is_self": False, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 200, "is_self": False, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 105, "is_self": True, "bound_owner": 100, "same_tab": True, "cwd": "/tmp/ovnfs-1"},
            ],
        }
        self.assertEqual(wingman.select_owner_pane_from_status(status_bound, 105), 100)

        # 2. Unbound fallback picks sole peer in same tab when unambiguous
        status_sole_peer = {
            "owner_pane": None,
            "agents": [
                {"pane": 100, "is_self": False, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 105, "is_self": True, "bound_owner": None, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 300, "is_self": False, "same_tab": False, "cwd": "/tmp/other"},
            ],
        }
        self.assertEqual(wingman.select_owner_pane_from_status(status_sole_peer, 105), 100)

        # 3. Refuses ambiguous multi-peer tab when unbound
        status_ambiguous = {
            "owner_pane": None,
            "agents": [
                {"pane": 100, "is_self": False, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 200, "is_self": False, "same_tab": True, "cwd": "/tmp/main"},
                {"pane": 105, "is_self": True, "bound_owner": None, "same_tab": True, "cwd": "/tmp/main"},
            ],
        }
        with self.assertRaises(SystemExit):
            wingman.select_owner_pane_from_status(status_ambiguous, 105)

        # 4. `is_caller_acp_agent` distinguishes Tern ACP panes (`agy`/`claude`) from plain shells and `omp` panes
        inspect_sample = {
            "panes": [
                {"pane": 50, "omp_session_file": None},  # plain zsh shell (not in status.agents)
                {"pane": 100, "omp_session_file": None},  # ACP agy pane (in status.agents, no omp_session_file)
                {"pane": 105, "omp_session_file": "/tmp/s105.jsonl"},  # omp worker pane
            ]
        }
        status_sample = {"agents": [{"pane": 100}, {"pane": 105}]}
        self.assertFalse(wingman.is_caller_acp_agent(status_sample, inspect_sample, 50))
        self.assertTrue(wingman.is_caller_acp_agent(status_sample, inspect_sample, 100))
        self.assertFalse(wingman.is_caller_acp_agent(status_sample, inspect_sample, 105))

    def test_windows_paths_cmdline_and_tcp_token_fallback(self) -> None:
        from unittest import mock

        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            local_app = Path(tmp) / "AppData" / "Local"
            tern_dir = local_app / "Programs" / "Tern"
            omp_dir = local_app / "Tern" / "omp" / "bin"
            tern_dir.mkdir(parents=True)
            omp_dir.mkdir(parents=True)
            (tern_dir / "tern.com").write_bytes(b"MZ")
            (tern_dir / "tern.exe").write_bytes(b"MZ")
            (omp_dir / "omp.exe").write_bytes(b"MZ")

            with mock.patch.object(wingman, "IS_WINDOWS", True), mock.patch.dict(
                wingman.os.environ, {"LOCALAPPDATA": str(local_app), "TERN_EXE": ""}, clear=False
            ):
                self.assertEqual(wingman.find_tern_bin(), str(tern_dir / "tern.com"))
                self.assertEqual(wingman.find_omp_bin(), str((omp_dir / "omp.exe").resolve()))
                self.assertEqual(wingman.bridge_ipc_dir(), local_app / "tern-wingman")
                quoted = wingman.format_command_line([r"C:\Program Files\omp\omp.exe", "--cwd", r"D:\My Repo"])
                self.assertIn('"C:\\Program Files\\omp\\omp.exe"', quoted)
                self.assertIn('"D:\\My Repo"', quoted)

            # Live loopback test of the authenticated 127.0.0.1 `.tcp` fallback when `socket.AF_UNIX` is absent
            ipc_tcp = Path(tmp) / "tcp-fallback"
            mux_proc = subprocess.Popen(
                [
                    sys.executable,
                    "-u",
                    "-c",
                    f"import socket, runpy, sys; delattr(socket, 'AF_UNIX'); sys.argv = [{str(MUX_PATH)!r}, {str(ipc_tcp)!r}]; runpy.run_path({str(MUX_PATH)!r}, run_name='__main__')",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            try:
                assert mux_proc.stdout and mux_proc.stdin
                ready = json.loads(mux_proc.stdout.readline())
                self.assertEqual(ready["type"], "ready")
                self.assertTrue(ready["sock"].endswith(".tcp"))

                # Reject unauthenticated TCP client
                meta = json.loads(Path(ready["sock"]).read_text(encoding="utf-8"))
                import socket as pysock

                bad = pysock.create_connection(("127.0.0.1", int(meta["port"])), timeout=2.0)
                try:
                    bad.sendall(b'{"op":"status","_token":"wrong"}\n')
                    bad_reply = json.loads(bad.makefile("r", encoding="utf-8").readline())
                    self.assertFalse(bad_reply["ok"])
                    self.assertIn("unauthorized", bad_reply["error"])
                finally:
                    bad.close()

                def drive_tcp_mux() -> None:
                    assert mux_proc.stdout and mux_proc.stdin
                    msg = json.loads(mux_proc.stdout.readline())
                    self.assertEqual(msg["req"]["op"], "status")
                    self.assertNotIn("_token", msg["req"])
                    mux_proc.stdin.write(json.dumps({"id": msg["id"], "reply": {"ok": True, "mode": "tcp-fallback"}}) + "\n")
                    mux_proc.stdin.flush()

                threading.Thread(target=drive_tcp_mux, daemon=True).start()
                with mock.patch.dict(wingman.os.environ, {"XDG_RUNTIME_DIR": ""}, clear=False), mock.patch.object(
                    wingman, "bridge_ipc_dir", return_value=ipc_tcp
                ):
                    res = wingman.call_bridge({"op": "status", "anchor_pane": 1}, timeout=3.0)
                    self.assertTrue(res["ok"])
                    self.assertEqual(res["mode"], "tcp-fallback")
            finally:
                if mux_proc.poll() is None:
                    mux_proc.terminate()
                    mux_proc.wait(timeout=2.0)
                for s in (mux_proc.stdin, mux_proc.stdout):
                    if s is not None and not s.closed:
                        s.close()

    def test_mux_unix_socket_multiwindow_ack_and_hot_reload_recovery(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            old_xdg = os.environ.get("XDG_RUNTIME_DIR")
            os.environ["XDG_RUNTIME_DIR"] = tmp
            ipc_dir = Path(tmp) / "tern-wingman"

            # Spawn Window A (wrong window -> replies `_skip`) and Window B (owns pane 42)
            mux_a = subprocess.Popen(
                [sys.executable, "-u", str(MUX_PATH), str(ipc_dir)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            mux_b = subprocess.Popen(
                [sys.executable, "-u", str(MUX_PATH), str(ipc_dir)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            mux_b2: subprocess.Popen[str] | None = None

            try:
                assert mux_a.stdout and mux_a.stdin and mux_b.stdout and mux_b.stdin
                ready_a = json.loads(mux_a.stdout.readline())
                ready_b = json.loads(mux_b.stdout.readline())
                self.assertEqual(ready_a["type"], "ready")
                self.assertEqual(ready_b["type"], "ready")

                def drive_mux_a() -> None:
                    assert mux_a.stdout and mux_a.stdin
                    for line in mux_a.stdout:
                        msg = json.loads(line)
                        if "req" in msg:
                            mux_a.stdin.write(json.dumps({"id": msg["id"], "reply": {"_skip": True}}) + "\n")
                            mux_a.stdin.flush()

                threading.Thread(target=drive_mux_a, daemon=True).start()

                def drive_mux_b_with_hot_reload() -> None:
                    nonlocal mux_b2
                    assert mux_b.stdout and mux_b.stdin
                    # 1. Handle initial `dispatch` on mux_b: send `_ack` (keep_open=True), then simulate plugin reload!
                    msg1 = json.loads(mux_b.stdout.readline())
                    self.assertEqual(msg1["req"]["op"], "dispatch")
                    mux_b.stdin.write(
                        json.dumps({"id": msg1["id"], "reply": {"_ack": True, "pane": 777}, "keep_open": True}) + "\n"
                    )
                    mux_b.stdin.flush()
                    time.sleep(0.05)
                    # Simulate `window.luau` reload by closing mux_b's stdin -> emits `_reload` to client!
                    mux_b.stdin.close()
                    mux_b.wait(timeout=2.0)

                    # Spawn replacement mux_b2 (new VM after reload) which receives seamless `op="await"` for pane 777!
                    mux_b2 = subprocess.Popen(
                        [sys.executable, "-u", str(MUX_PATH), str(ipc_dir)],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        text=True,
                    )
                    assert mux_b2.stdout and mux_b2.stdin
                    ready_b2 = json.loads(mux_b2.stdout.readline())
                    self.assertEqual(ready_b2["type"], "ready")
                    msg2 = json.loads(mux_b2.stdout.readline())
                    self.assertEqual(msg2["req"]["op"], "await")
                    self.assertEqual(msg2["req"]["target_pane"], 777)
                    mux_b2.stdin.write(
                        json.dumps({"id": msg2["id"], "reply": {"_ack": True, "pane": 777}, "keep_open": True}) + "\n"
                    )
                    mux_b2.stdin.write(
                        json.dumps(
                            {
                                "id": msg2["id"],
                                "reply": {"ok": True, "pane": 777, "status": "done", "last_message": "RELOAD_SURVIVED"},
                                "keep_open": False,
                            }
                        )
                        + "\n"
                    )
                    mux_b2.stdin.flush()

                threading.Thread(target=drive_mux_b_with_hot_reload, daemon=True).start()

                acked: list[int] = []
                reply = wingman.call_bridge(
                    {"op": "dispatch", "anchor_pane": 42, "prompt": "hi"},
                    timeout=4.0,
                    on_ack=lambda f: acked.append(int(f["pane"])),
                )
                self.assertEqual(acked, [777])
                self.assertTrue(reply["ok"])
                self.assertEqual(reply["last_message"], "RELOAD_SURVIVED")
            finally:
                for p in (mux_a, mux_b, mux_b2):
                    if p is not None:
                        if p.poll() is None:
                            p.terminate()
                            p.wait(timeout=2.0)
                        for stream in (p.stdin, p.stdout):
                            if stream is not None and not stream.closed:
                                stream.close()
                if old_xdg is None:
                    os.environ.pop("XDG_RUNTIME_DIR", None)
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old_xdg

    def test_read_prompt_input_dash_reads_piped_stdin(self) -> None:
        class _FakeStdin:
            def __init__(self, text: str, tty: bool) -> None:
                self._text = text
                self._tty = tty

            def isatty(self) -> bool:
                return self._tty

            def read(self) -> str:
                return self._text

        with unittest.mock.patch.object(wingman.sys, "stdin", _FakeStdin("  heredoc body\n", tty=False)):
            self.assertEqual(wingman._read_prompt_input("-", None), "heredoc body")
        with unittest.mock.patch.object(wingman.sys, "stdin", _FakeStdin("", tty=True)):
            self.assertEqual(wingman._read_prompt_input("-", None), "-")


def _agent(pane: int, cwd: str = "/tmp/work", **extra: object) -> dict:
    return {"pane": pane, "is_self": False, "same_tab": True, "cwd": cwd, "state": "idle", **extra}


def _multi_status(bound: list[int], extra_agents: list[dict] | None = None, cwds: dict[int, str] | None = None) -> dict:
    cwds = cwds or {}
    agents = [{"pane": 100, "is_self": True, "same_tab": True, "cwd": "/tmp/main", "state": "working"}]
    agents += [_agent(p, cwds.get(p, "/tmp/work"), bound_owner=100, is_bound_to_me=True) for p in bound]
    agents += extra_agents or []
    status: dict = {"ok": True, "bound_panes": sorted(bound), "agents": agents}
    if len(bound) == 1:
        status["bound_pane"] = bound[0]
    return status


class WingmanMultiWorkerTests(unittest.TestCase):
    def _patched(self, status: dict, bridge_log: list[dict], reply: dict | None = None):
        from contextlib import ExitStack
        from unittest import mock

        def fake_bridge(req, timeout=None, on_ack=None):
            bridge_log.append(req)
            if req["op"] == "status":
                return status
            return reply if reply is not None else {"ok": True, "pane": 777, "status": "done", "last_message": "ok"}

        stack = ExitStack()
        stack.enter_context(mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}))
        stack.enter_context(mock.patch.object(wingman, "call_bridge", fake_bridge))
        stack.enter_context(mock.patch.object(wingman, "find_omp_bin", lambda: "omp"))
        stack.enter_context(mock.patch.object(wingman, "find_tern_bin", lambda: None))
        stack.enter_context(mock.patch.object(wingman, "inspect_tern", lambda _b: None))
        stack.enter_context(mock.patch("sys.stdout"))
        stack.enter_context(mock.patch("sys.stderr"))
        return stack

    def _send(self, argv: list[str], status: dict) -> tuple[list[dict], object]:
        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", *argv, "-m", "go", "--wait"])
        with self._patched(status, calls):
            with self.assertRaises(SystemExit) as cm:
                ns.func(ns)
        return calls, cm.exception.code

    def _dispatch(self, argv: list[str], status: dict) -> dict:
        calls, code = self._send(argv, status)
        self.assertEqual(code, 0)
        dispatches = [c for c in calls if c["op"] == "dispatch"]
        self.assertEqual(len(dispatches), 1)
        return dispatches[0]

    def _send_error(self, argv: list[str], status: dict) -> tuple[list[dict], str]:
        calls, code = self._send(argv, status)
        self.assertIsInstance(code, str)
        self.assertFalse([c for c in calls if c["op"] == "dispatch"], "must not dispatch on error")
        return calls, str(code)

    def test_bound_panes_from_status_prefers_list_and_falls_back_to_legacy(self) -> None:
        self.assertEqual(wingman.bound_panes_from_status({"bound_panes": [107, 105, 105]}), [105, 107])
        self.assertEqual(wingman.bound_panes_from_status({"bound_panes": [100, 105]}, exclude=100), [105])
        self.assertEqual(wingman.bound_panes_from_status({"bound_panes": []}), [])
        # Old plugin only reports the singular field
        self.assertEqual(wingman.bound_panes_from_status({"bound_pane": 105}), [105])
        self.assertEqual(wingman.bound_panes_from_status({"bound_pane": None, "agents": []}), [])
        # New list wins over a stale singular value
        self.assertEqual(wingman.bound_panes_from_status({"bound_panes": [106, 107], "bound_pane": 105}), [106, 107])

    def test_new_spawns_additional_worker_without_target_even_when_bound(self) -> None:
        req = self._dispatch(["new"], _multi_status([105, 106]))
        self.assertIsNone(req["target_pane"])
        self.assertFalse(req["reset_new"])
        self.assertEqual(req["layout"], "split")
        self.assertNotIn("pip_corner", req)
        req = self._dispatch(["new"], _multi_status([105]))
        self.assertIsNone(req["target_pane"])
        self.assertFalse(req["reset_new"])

    def test_new_replace_selects_sole_explicit_or_unique_cwd_owned_worker(self) -> None:
        req = self._dispatch(["new", "--replace"], _multi_status([105]))
        self.assertEqual((req["target_pane"], req["reset_new"]), (105, True))
        self.assertNotIn("layout", req)  # existing target keeps its placement

        two = _multi_status([105, 106], cwds={105: "/tmp/a", 106: "/tmp/b"})
        req = self._dispatch(["new", "--replace", "--pane", "106"], two)
        self.assertEqual((req["target_pane"], req["reset_new"]), (106, True))
        req = self._dispatch(["new", "--replace", "--cwd", "/tmp/b"], two)
        self.assertEqual((req["target_pane"], req["reset_new"]), (106, True))

        # Replace with a layout re-places the replaced worker explicitly
        req = self._dispatch(["new", "--replace", "--layout", "tab"], _multi_status([105]))
        self.assertEqual((req["target_pane"], req["reset_new"], req["layout"]), (105, True, "tab"))

    def test_new_replace_errors_instead_of_guessing_or_closing_unowned_panes(self) -> None:
        two = _multi_status([105, 106], cwds={105: "/tmp/a", 106: "/tmp/b"})
        _, msg = self._send_error(["new", "--replace"], two)
        self.assertIn("105", msg)
        self.assertIn("106", msg)
        self.assertIn("--pane", msg)
        # Explicit --cwd that matches none (or several) never auto-selects
        _, msg = self._send_error(["new", "--replace", "--cwd", "/tmp/c"], two)
        self.assertIn("--pane", msg)
        # Unowned pane (peer wingman, manual omp) must not be replaceable via --pane
        manual = _agent(200, bound_owner=None)
        _, msg = self._send_error(["new", "--replace", "--pane", "200"], _multi_status([105], [manual]))
        self.assertIn("not a wingman bound", msg)
        # No bound worker -> there is nothing to replace, even with an unclaimed pane in the tab
        _, msg = self._send_error(["new", "--replace"], _multi_status([], [_agent(200)]))
        self.assertIn("no replacement target", msg)

    def test_new_replace_works_with_legacy_status_bound_pane(self) -> None:
        legacy = {"ok": True, "bound_pane": 105, "agents": [_agent(105, bound_owner=100)]}
        req = self._dispatch(["new", "--replace"], legacy)
        self.assertEqual((req["target_pane"], req["reset_new"]), (105, True))
        req = self._dispatch(["same"], legacy)
        self.assertEqual((req["target_pane"], req["reset_new"]), (105, False))

    def test_same_requires_pane_or_cwd_when_several_owned_workers(self) -> None:
        three = _multi_status([105, 106, 107], cwds={105: "/tmp/a", 106: "/tmp/b", 107: "/tmp/b"})
        _, msg = self._send_error(["same"], three)
        for pid in ("105", "106", "107"):
            self.assertIn(pid, msg)
        self.assertIn("--pane", msg)
        # A unique cwd disambiguates; an ambiguous cwd still errors rather than picking first
        req = self._dispatch(["same", "--cwd", "/tmp/a"], three)
        self.assertEqual(req["target_pane"], 105)
        self._send_error(["same", "--cwd", "/tmp/b"], three)
        # Exact pane always wins
        req = self._dispatch(["same", "--pane", "107"], three)
        self.assertEqual((req["target_pane"], req["reset_new"]), (107, False))
        self.assertNotIn("layout", req)

    def test_same_adopts_unclaimed_omp_only_when_no_bound_worker(self) -> None:
        cwd = Path("/tmp/demo-repo")
        inspect_data = {"panes": [{"pane": 102, "omp_session_file": "/tmp/s102.jsonl"}]}
        manual = _agent(102, str(cwd), bound_owner=None)
        status = _multi_status([], [manual])
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, inspect_data, cwd, "same", None, anchor_pane=100),
            (102, False),
        )
        # With an owned worker the manual pane is never considered
        owned = _multi_status([105], [manual])
        self.assertEqual(
            wingman.resolve_target_pane_from_status(owned, inspect_data, cwd, "same", None, anchor_pane=100),
            (105, False),
        )
        # Nothing owned and nothing adoptable -> no target
        self.assertEqual(
            wingman.resolve_target_pane_from_status(_multi_status([]), inspect_data, cwd, "same", None, anchor_pane=100),
            (None, False),
        )
        # Explicit session resume keeps matching by authoritative session file, regardless of ownership
        sess = Path("/tmp/s102.jsonl")
        resume_inspect = {"panes": [{"pane": 102, "omp_session_file": str(sess.resolve())}]}
        self.assertEqual(
            wingman.resolve_target_pane_from_status(owned, resume_inspect, cwd, "latest", sess, anchor_pane=100),
            (102, False),
        )

    def test_every_layout_is_forwarded_for_fresh_and_existing_targets(self) -> None:
        for layout in ("split", "down", "tab", "park"):
            with self.subTest(layout=layout, target="fresh"):
                req = self._dispatch(["new", "--layout", layout], _multi_status([]))
                self.assertEqual((req["layout"], req["target_pane"], req["reset_new"]), (layout, None, False))
                self.assertNotIn("pip_corner", req)
            with self.subTest(layout=layout, target="existing"):
                req = self._dispatch(["same", "--layout", layout], _multi_status([105]))
                self.assertEqual((req["layout"], req["target_pane"], req["reset_new"]), (layout, 105, False))
                self.assertNotIn("pip_corner", req)

        for target_argv, status in ((["new"], _multi_status([])), (["same"], _multi_status([105]))):
            with self.subTest(layout="pip", argv=target_argv):
                # `--layout pip` alone defaults to the bottom-right corner
                req = self._dispatch([*target_argv, "--layout", "pip"], status)
                self.assertEqual((req["layout"], req["pip_corner"]), ("pip", "br"))
                # `--layout pip --pip <corner>` and legacy `--pip <corner>` alone are equivalent
                for corner in ("tl", "tr", "bl", "br"):
                    both = self._dispatch([*target_argv, "--layout", "pip", "--pip", corner], status)
                    alone = self._dispatch([*target_argv, "--pip", corner], status)
                    self.assertEqual((both["layout"], both["pip_corner"]), ("pip", corner))
                    self.assertEqual((alone["layout"], alone["pip_corner"]), ("pip", corner))
                    self.assertEqual(both["target_pane"], alone["target_pane"])

    def test_pip_flag_alone_and_with_layout_pip_target_existing_worker(self) -> None:
        req = self._dispatch(["same", "--pip", "tl"], _multi_status([105]))
        self.assertEqual((req["layout"], req["pip_corner"], req["target_pane"]), ("pip", "tl", 105))
        req = self._dispatch(["same", "--layout", "pip", "--pip", "tl"], _multi_status([105]))
        self.assertEqual((req["layout"], req["pip_corner"], req["target_pane"]), ("pip", "tl", 105))

    def test_existing_target_without_layout_keeps_placement_and_dispatch_command_is_unchanged(self) -> None:
        req = self._dispatch(["same"], _multi_status([105]))
        self.assertNotIn("layout", req)
        self.assertNotIn("pip_corner", req)
        self.assertEqual(
            set(req),
            {"op", "anchor_pane", "target_pane", "reset_new", "queue", "async_callback", "cwd", "command", "prompt"},
        )
        self.assertEqual(req["command"], wingman.format_command_line(["omp", "--auto-approve", "--cwd", req["cwd"]]))
        self.assertEqual(req["prompt"], "go")

    def test_send_flag_conflicts_are_rejected_before_any_bridge_call(self) -> None:
        cases = {
            "--pip conflicts": ["new", "--pip", "tl", "--layout", "down"],
            "--pip conflicts with --layout tab": ["new", "--layout", "tab", "--pip", "tl"],
            "--pip conflicts with --layout split": ["same", "--layout", "split", "--pip", "br"],
            "only applies to `send new`": ["same", "--replace"],
            "only applies to `send same`": ["new", "--pane", "105"],
            "own pane": ["same", "--pane", "100"],
            "invalid pane": ["same", "--pane", "abc"],
        }
        for needle, argv in cases.items():
            with self.subTest(needle=needle):
                calls, msg = self._send_error(argv, _multi_status([105]))
                self.assertIn(needle, msg)
                self.assertEqual(calls, [])
        # --pane is not meaningful for resume-by-session or latest
        _, msg = self._send_error(["latest", "--pane", "105"], _multi_status([105]))
        self.assertIn("only applies", msg)

    def test_headless_rejects_tern_only_placement_flags(self) -> None:
        from unittest import mock

        parser = wingman.build_parser()
        for flags in (
            ["new", "--pane", "105"],
            ["new", "--replace"],
            ["new", "--layout", "tab"],
            ["new", "--pip", "tl"],
        ):
            with self.subTest(flags=flags):
                ns = parser.parse_args(["send", *flags, "-m", "hi", "--mode", "headless"])
                with mock.patch.object(wingman.subprocess, "Popen") as popen, self.assertRaises(SystemExit) as cm:
                    ns.func(ns)
                self.assertIn("headless", str(cm.exception.code))
                popen.assert_not_called()
        # Outside Tern (`auto` with no $TERN_PANE) is headless too
        ns = parser.parse_args(["send", "new", "--layout", "tab", "-m", "hi"])
        with mock.patch.dict(wingman.os.environ, {}, clear=False):
            wingman.os.environ.pop("TERN_PANE", None)
            with mock.patch.object(wingman.subprocess, "Popen") as popen, self.assertRaises(SystemExit) as cm:
                ns.func(ns)
        self.assertIn("headless", str(cm.exception.code))
        popen.assert_not_called()

    def _control(self, subcmd: str, argv: list[str], status: dict) -> tuple[list[dict], object]:
        calls: list[dict] = []
        ns = wingman.build_parser().parse_args([subcmd, *argv])
        with self._patched(status, calls, reply={"ok": True}):
            try:
                ns.func(ns)
                code = None
            except SystemExit as exc:
                code = exc.code
        return calls, code

    def test_park_unpark_use_bound_list_and_exact_pane(self) -> None:
        for sub in ("park", "unpark"):
            with self.subTest(sub=sub, how="sole bound"):
                calls, code = self._control(sub, [], _multi_status([105]))
                self.assertIsNone(code)
                self.assertEqual(calls[-1], {"op": sub, "anchor_pane": 100, "target_pane": 105})
            with self.subTest(sub=sub, how="explicit pane among many"):
                calls, code = self._control(sub, ["--pane", "106"], _multi_status([105, 106]))
                self.assertIsNone(code)
                self.assertEqual(calls, [{"op": sub, "anchor_pane": 100, "target_pane": 106}])  # no status lookup needed
            with self.subTest(sub=sub, how="positional pane"):
                calls, _ = self._control(sub, ["107"], _multi_status([105, 106]))
                self.assertEqual(calls[-1]["target_pane"], 107)
            with self.subTest(sub=sub, how="self rejected"):
                calls, code = self._control(sub, ["--pane", "100"], _multi_status([105]))
                self.assertIn("own pane", str(code))
                self.assertEqual(calls, [])
            with self.subTest(sub=sub, how="bridge error"):
                calls = []
                ns = wingman.build_parser().parse_args([sub, "--pane", "105"])
                with self._patched({}, calls, reply={"ok": False, "error": "not a worker"}):
                    with self.assertRaises(SystemExit) as cm:
                        ns.func(ns)
                self.assertIn("not a worker", str(cm.exception.code))

    def test_controls_never_pick_first_of_multiple_bound_workers(self) -> None:
        status = _multi_status([105, 106], cwds={105: "/tmp/a", 106: "/tmp/b"})
        for sub in ("park", "unpark", "stop", "interrupt", "pip", "dock", "transcript"):
            with self.subTest(sub=sub):
                calls, code = self._control(sub, [], status)
                self.assertIn("105", str(code))
                self.assertIn("106", str(code))
                self.assertIn("--pane", str(code))
                self.assertEqual([c["op"] for c in calls], ["status"])
        # Explicit --cwd picks only a unique match
        calls, code = self._control("park", ["--cwd", "/tmp/b"], status)
        self.assertIsNone(code)
        self.assertEqual(calls[-1]["target_pane"], 106)
        calls, code = self._control("park", ["--cwd", "/tmp/zzz"], status)
        self.assertIsInstance(code, str)
        self.assertEqual([c["op"] for c in calls], ["status"])

    def test_controls_fall_back_to_manual_adoption_only_without_bound_workers(self) -> None:
        cwd = Path("/tmp/demo-repo")
        inspect_data = {"panes": [{"pane": 102, "omp_session_file": "/tmp/s102.jsonl"}]}
        manual = _agent(102, str(cwd))
        self.assertEqual(wingman.select_wingman_pane_from_status(_multi_status([], [manual]), inspect_data, 100, cwd=cwd), 102)
        # Owned worker 105 is chosen even though a manual omp pane exists
        self.assertEqual(wingman.select_wingman_pane_from_status(_multi_status([105], [manual]), inspect_data, 100), 105)
        with self.assertRaises(SystemExit):
            wingman.select_wingman_pane_from_status(_multi_status([]), inspect_data, 100)
        # Legacy status with only `bound_pane`
        self.assertEqual(wingman.select_wingman_pane_from_status({"bound_pane": 105, "agents": []}, None, 100), 105)

    def test_info_reports_all_bound_panes_plus_singular_and_placement_flags(self) -> None:
        import io
        from contextlib import redirect_stdout
        from unittest import mock

        def info_for(status: dict) -> dict:
            with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
                ns = wingman.build_parser().parse_args(["info", "--cwd", tmp])
                buf = io.StringIO()
                with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(
                    wingman, "find_omp_bin", lambda: "omp"
                ), mock.patch.object(wingman, "find_tern_bin", lambda: None), mock.patch.object(
                    wingman, "find_ovnfs_bin", lambda: None
                ), mock.patch.object(wingman, "get_collab_hosts", lambda _b: {}), mock.patch.object(
                    wingman, "call_bridge", lambda req, timeout=None: status
                ), mock.patch.object(wingman, "inspect_tern", lambda _b: None), redirect_stdout(buf):
                    ns.func(ns)
                return json.loads(buf.getvalue())

        many = _multi_status([107, 105])
        many["agents"][1]["parked"] = True
        many["agents"][2]["floating"] = True
        out = info_for(many)
        self.assertEqual(out["boundWingmanPanes"], [105, 107])
        self.assertIsNone(out["boundWingmanPane"])
        by_pane = {a["pane"]: a for a in out["ternAgents"]}
        self.assertTrue(by_pane[107]["parked"])
        self.assertTrue(by_pane[105]["floating"])
        self.assertTrue(by_pane[105]["isBoundToMe"])

        out = info_for(_multi_status([105]))
        self.assertEqual((out["boundWingmanPanes"], out["boundWingmanPane"]), ([105], 105))
        out = info_for(_multi_status([]))
        self.assertEqual((out["boundWingmanPanes"], out["boundWingmanPane"]), ([], None))
        # Old plugin: only singular bound_pane
        out = info_for({"ok": True, "bound_pane": 105, "agents": [_agent(105, bound_owner=100)]})
        self.assertEqual((out["boundWingmanPanes"], out["boundWingmanPane"]), ([105], 105))


if __name__ == "__main__":
    unittest.main()
