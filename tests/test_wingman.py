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


def mock_stdout(buf):
    from unittest import mock

    return mock.patch("sys.stdout", buf)


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
        self.assertEqual(wingman.select_wingman_pane_from_status(status, 100, cwd=lead_cwd), 105)

    def test_unbound_adoption_prefers_cwd_and_respects_other_owners(self) -> None:
        cwd = Path("/tmp/demo-repo")
        status = {
            "bound_pane": None,
            "agents": [
                {"pane": 100, "is_self": True, "same_tab": True, "cwd": str(cwd), "state": "working"},
                {"pane": 201, "is_self": False, "bound_owner": 200, "same_tab": True, "cwd": str(cwd), "state": "idle"},
                {"pane": 300, "is_self": False, "bound_owner": None, "same_tab": False, "cwd": str(cwd), "state": "idle"},
                {"pane": 101, "is_self": False, "bound_owner": None, "same_tab": True, "cwd": "/tmp/other", "state": "idle"},
                {"pane": 102, "is_self": False, "bound_owner": None, "same_tab": True, "cwd": str(cwd), "state": "idle"},
            ],
        }
        # Never self (100), peer-owned (201) or other-tab (300); cwd match (102) beats first unclaimed (101)
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, cwd, "same", None, anchor_pane=100),
            (102, False),
        )
        self.assertEqual(wingman.select_wingman_pane_from_status(status, 100, cwd=cwd), 102)
        # No cwd match: falls back to the first unclaimed agent
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, Path("/tmp/none"), "same", None, anchor_pane=100),
            (101, False),
        )
        # `new` spawns a fresh split without touching the unclaimed pane
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, cwd, "new", None, anchor_pane=100),
            (None, False),
        )
        # Only self and peer-owned agents: nothing to adopt
        only_owned = {"agents": [status["agents"][0], status["agents"][1]]}
        with self.assertRaises(SystemExit):
            wingman.select_wingman_pane_from_status(only_owned, 100, cwd=cwd)

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

    def test_is_caller_tern_agent_detection(self) -> None:
        # `is_caller_tern_agent` is true for any pane listed in status.agents (ACP or omp), false for plain shells
        status_sample = {"agents": [{"pane": 100}, {"pane": 105}]}
        self.assertFalse(wingman.is_caller_tern_agent(status_sample, 50))
        self.assertTrue(wingman.is_caller_tern_agent(status_sample, 100))
        self.assertTrue(wingman.is_caller_tern_agent(status_sample, 105))

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
        stack.enter_context(mock.patch.object(wingman, "find_omp_bin", lambda required=True: "omp"))
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

    def test_same_adopts_unclaimed_agent_only_when_no_bound_worker(self) -> None:
        cwd = Path("/tmp/demo-repo")
        manual = _agent(102, str(cwd), bound_owner=None)
        status = _multi_status([], [manual])
        # No inspect data needed: any live unowned same-tab agent qualifies
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, cwd, "same", None, anchor_pane=100),
            (102, False),
        )
        # With an owned worker the manual pane is never considered
        owned = _multi_status([105], [manual])
        self.assertEqual(
            wingman.resolve_target_pane_from_status(owned, None, cwd, "same", None, anchor_pane=100),
            (105, False),
        )
        # Nothing owned and nothing adoptable -> no target
        self.assertEqual(
            wingman.resolve_target_pane_from_status(_multi_status([]), None, cwd, "same", None, anchor_pane=100),
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
                # `--layout pip` alone leaves `pip_corner` unset so `window.luau` picks a free corner
                req = self._dispatch([*target_argv, "--layout", "pip"], status)
                self.assertEqual(req["layout"], "pip")
                self.assertNotIn("pip_corner", req)
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

    def test_existing_target_has_no_launch_command_and_spawn_command_is_unchanged(self) -> None:
        from unittest import mock

        def forbidden(*_a: object, **_k: object) -> None:
            raise AssertionError("omp must not be located for an existing target")

        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", "same", "-m", "go", "--wait"])
        with self._patched(_multi_status([105]), calls) as stack:
            stack.enter_context(mock.patch.object(wingman, "find_omp_bin", forbidden))
            with self.assertRaises(SystemExit):
                ns.func(ns)
        req = [c for c in calls if c["op"] == "dispatch"][0]
        self.assertNotIn("layout", req)
        self.assertNotIn("pip_corner", req)
        self.assertEqual(
            set(req),
            {"op", "anchor_pane", "target_pane", "reset_new", "queue", "async_callback", "cwd", "prompt"},
        )
        self.assertEqual(req["prompt"], "go")
        # Spawning keeps the default omp command
        req = self._dispatch(["new"], _multi_status([105]))
        self.assertEqual(req["command"], wingman.format_command_line(["omp", "--auto-approve", "--cwd", req["cwd"]]))

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

    def test_controls_fall_back_to_unclaimed_adoption_only_without_bound_workers(self) -> None:
        cwd = Path("/tmp/demo-repo")
        manual = _agent(102, str(cwd))
        self.assertEqual(wingman.select_wingman_pane_from_status(_multi_status([], [manual]), 100, cwd=cwd), 102)
        # Owned worker 105 is chosen even though an unclaimed pane exists
        self.assertEqual(wingman.select_wingman_pane_from_status(_multi_status([105], [manual]), 100), 105)
        with self.assertRaises(SystemExit):
            wingman.select_wingman_pane_from_status(_multi_status([]), 100)
        # Legacy status with only `bound_pane`
        self.assertEqual(wingman.select_wingman_pane_from_status({"bound_pane": 105, "agents": []}, 100), 105)

    def _acp_dispatch(self, argv: list[str], status: dict, tern: str | None = "/opt/tern") -> dict:
        from unittest import mock

        def forbidden(*_a: object, **_k: object) -> None:
            raise AssertionError("omp / inspect must not be consulted for native ACP agents")

        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", *argv, "-m", "go", "--wait"])
        with self._patched(status, calls) as stack:
            stack.enter_context(mock.patch.object(wingman, "find_omp_bin", forbidden))
            stack.enter_context(mock.patch.object(wingman, "inspect_tern", forbidden))
            stack.enter_context(mock.patch.object(wingman, "find_tern_bin", lambda: tern))
            with self.assertRaises(SystemExit) as cm:
                ns.func(ns)
        self.assertEqual(cm.exception.code, 0)
        dispatches = [c for c in calls if c["op"] == "dispatch"]
        self.assertEqual(len(dispatches), 1)
        return dispatches[0]

    def _acp_error(self, argv: list[str], status: dict | None = None, env_pane: bool = True) -> str:
        from unittest import mock

        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", *argv, "-m", "go", "--wait"])
        with self._patched(status or _multi_status([]), calls) as stack:
            stack.enter_context(mock.patch.object(wingman, "find_tern_bin", lambda: "/opt/tern"))
            if not env_pane:
                wingman.os.environ.pop("TERN_PANE", None)
            with mock.patch.object(wingman.subprocess, "Popen") as popen, self.assertRaises(SystemExit) as cm:
                ns.func(ns)
            popen.assert_not_called()
        self.assertFalse([c for c in calls if c["op"] == "dispatch"])
        self.assertIsInstance(cm.exception.code, str)
        return str(cm.exception.code)

    def test_native_acp_agent_launch_argv_model_resume_and_continue(self) -> None:
        status = _multi_status([])
        req = self._acp_dispatch(["new", "--agent", "agy"], status)
        self.assertEqual(req["command"], wingman.format_command_line(["/opt/tern", "acp", "agy"]))
        self.assertIsNone(req["target_pane"])
        self.assertEqual(req["layout"], "split")
        self.assertNotIn("--cwd", req["command"])
        self.assertNotIn("--prompt", req["command"])
        req = self._acp_dispatch(["new", "--agent", "claude", "--model", "opus"], status)
        self.assertEqual(req["command"], wingman.format_command_line(["/opt/tern", "acp", "claude", "--model", "opus"]))
        # `latest` -> native --continue; explicit id passes through opaquely (not resolved as an omp session)
        req = self._acp_dispatch(["latest", "--agent", "codex"], status)
        self.assertEqual(req["command"], wingman.format_command_line(["/opt/tern", "acp", "codex", "--continue"]))
        req = self._acp_dispatch(["abc-123", "--agent", "codex", "--model", "m"], status)
        self.assertEqual(
            req["command"],
            wingman.format_command_line(["/opt/tern", "acp", "codex", "--resume", "abc-123", "--model", "m"]),
        )
        req = self._acp_dispatch(["/some/path with space", "--agent", "copilot"], status)
        self.assertIn("--resume", req["command"])
        self.assertIn("/some/path with space", __import__("shlex").split(req["command"]))

    def test_native_acp_same_reattaches_and_adopts_without_launch_binaries(self) -> None:
        # Reattach to an owned worker: no tern launch executable required, no resume args
        req = self._acp_dispatch(["same", "--agent", "agy"], _multi_status([105]), tern=None)
        self.assertEqual(req["target_pane"], 105)
        self.assertNotIn("command", req)
        # Unclaimed same-tab agent is adopted (cwd preferred) regardless of agent id
        cwd = "/tmp/proj"
        extra = [_agent(201, "/tmp/other"), _agent(202, cwd)]
        req = self._acp_dispatch(["same", "--agent", "agy", "--cwd", cwd], _multi_status([], extra), tern=None)
        self.assertEqual(req["target_pane"], 202)
        req = self._acp_dispatch(["same", "--agent", "agy"], _multi_status([], extra), tern=None)
        self.assertEqual(req["target_pane"], 201)

    def test_native_acp_rejections(self) -> None:
        self.assertIn("--thinking", self._acp_error(["new", "--agent", "agy", "--thinking", "high"]))
        self.assertIn("--takeover-idle", self._acp_error(["new", "--agent", "agy", "--takeover-idle"]))
        self.assertIn("--allow-fork", self._acp_error(["new", "--agent", "agy", "--allow-fork"]))
        self.assertIn("headless", self._acp_error(["new", "--agent", "agy", "--mode", "headless"]))
        self.assertIn("headless", self._acp_error(["new", "--agent", "agy"], env_pane=False))
        for bad in ("-agy", "Agy", "a b", "x" * 65, ""):
            with self.subTest(agent=bad):
                self.assertIn("invalid --agent", self._acp_error(["new", f"--agent={bad}"]))
        # Launching needs the `tern` CLI
        from unittest import mock

        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", "new", "--agent", "agy", "-m", "go", "--wait"])
        with self._patched(_multi_status([]), calls), self.assertRaises(SystemExit) as cm:
            ns.func(ns)
        self.assertIn("`tern` CLI", str(cm.exception.code))
        self.assertEqual([c["op"] for c in calls], ["status"])

    def test_bridge_cycle_error_is_passed_through_unmodified(self) -> None:
        from unittest import mock

        message = "cannot bind pane 105: would create an ownership cycle"
        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(["send", "same", "--pane", "105", "-m", "go", "--wait"])
        err = __import__("io").StringIO()
        with self._patched(_multi_status([]), calls, reply={"ok": False, "status": "failed", "error": message}) as stack:
            stack.enter_context(mock.patch("sys.stderr", err))
            with self.assertRaises(SystemExit) as cm:
                ns.func(ns)
        self.assertEqual(cm.exception.code, 1)
        self.assertIn(f"[wingman] Worker finished with status=failed: {message}", err.getvalue())

    def test_auto_delivery_is_async_iff_caller_is_listed_in_status_agents(self) -> None:
        from unittest import mock

        def forbidden(*_a: object, **_k: object) -> None:
            raise AssertionError("no inspect for caller detection")

        def auto_req(status: dict, retry: bool = False) -> dict:
            calls: list[dict] = []
            argv = ["retry", "105"] if retry else ["send", "new", "-m", "go"]
            ns = wingman.build_parser().parse_args(argv)
            with self._patched(status, calls) as stack:
                stack.enter_context(mock.patch.object(wingman, "inspect_tern", forbidden))
                if retry:
                    ns.func(ns)
                else:
                    with self.assertRaises(SystemExit) as cm:
                        ns.func(ns)
                    self.assertEqual(cm.exception.code, 0)
            op = "retry" if retry else "dispatch"
            return next(c for c in calls if c["op"] == op)

        listed = _multi_status([105])  # caller 100 (omp or ACP alike) is in status.agents
        shell = {"ok": True, "agents": [_agent(105, bound_owner=None)]}
        for retry in (False, True):
            with self.subTest(retry=retry):
                self.assertTrue(auto_req(listed, retry)["async_callback"])
                self.assertFalse(auto_req(shell, retry)["async_callback"])

    def test_info_reports_all_bound_panes_plus_singular_and_placement_flags(self) -> None:
        import io
        from contextlib import redirect_stdout
        from unittest import mock

        def info_for(status: dict) -> dict:
            with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
                ns = wingman.build_parser().parse_args(["info", "--cwd", tmp])
                buf = io.StringIO()
                with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(
                    wingman, "find_omp_bin", lambda required=True: "omp"
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

    def _info(self, status: dict, omp: str | None, inspect_data: dict | None = None) -> dict:
        import io
        from contextlib import redirect_stdout
        from unittest import mock

        def no_omp(*_a: object, **_k: object) -> None:
            raise AssertionError("omp must not be consulted when it is missing")

        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            ns = wingman.build_parser().parse_args(["info", "--cwd", tmp])
            buf = io.StringIO()
            with mock.patch.dict(wingman.os.environ, {"TERN_PANE": "100"}), mock.patch.object(
                wingman, "find_omp_bin", lambda required=True: omp
            ), mock.patch.object(wingman, "find_tern_bin", lambda: "/bin/tern"), mock.patch.object(
                wingman, "find_ovnfs_bin", lambda: None
            ), mock.patch.object(wingman, "get_collab_hosts", (lambda _b: {}) if omp else no_omp), mock.patch.object(
                wingman, "check_leases", (lambda _b, _s: set()) if omp else no_omp
            ), mock.patch.object(wingman, "call_bridge", lambda req, timeout=None: status), mock.patch.object(
                wingman, "inspect_tern", lambda _b: inspect_data
            ), redirect_stdout(buf):
                ns.func(ns)
            return json.loads(buf.getvalue())

    def test_info_kind_comes_only_from_omp_session_file_and_omp_is_optional(self) -> None:
        status = _multi_status([105], [_agent(106)])
        inspect_data = {"panes": [{"pane": 105, "omp_session_file": "/tmp/s105.jsonl"}, {"pane": 106, "omp_session_file": None}]}
        out = self._info(status, "omp", inspect_data)
        kinds = {a["pane"]: a["kind"] for a in out["ternAgents"]}
        self.assertEqual((kinds[105], kinds[106]), ("omp", "acp"))
        self.assertEqual(out["ompBin"], "omp")
        # Without omp installed `info` still works and reports the native agents
        out = self._info(status, None, inspect_data)
        self.assertIsNone(out["ompBin"])
        self.assertEqual(out["boundWingmanPanes"], [105])
        self.assertEqual({a["pane"] for a in out["ternAgents"]}, {100, 105, 106})

    def test_find_omp_bin_not_required_returns_none_when_absent(self) -> None:
        from unittest import mock

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(wingman, "home_dir", lambda: Path(tmp)), mock.patch.object(
            wingman.shutil, "which", lambda _n: None
        ), mock.patch.dict(wingman.os.environ, {"LOCALAPPDATA": ""}):
            self.assertIsNone(wingman.find_omp_bin(required=False))
            with self.assertRaises(SystemExit):
                wingman.find_omp_bin()

    def _run_cli(self, argv: list[str], reply: dict | None = None) -> tuple[list[dict], str | int | None, str]:
        import io

        calls: list[dict] = []
        ns = wingman.build_parser().parse_args(argv)
        out = io.StringIO()
        with self._patched({"ok": True, "agents": []}, calls, reply):
            with mock_stdout(out):
                try:
                    ns.func(ns)
                    code = None
                except SystemExit as exc:
                    code = exc.code
        return calls, code, out.getvalue()

    def test_queue_cli_parsing_and_forwarding(self) -> None:
        reply = {"ok": True, "items": [{"id": 11}], "pane": 105, "cancelled": 1, "remaining": 0}
        calls, code, out = self._run_cli(["queue", "list", "--all"], reply)
        self.assertIsNone(code)
        req = calls[0]
        self.assertEqual((req["op"], req["action"], req["anchor_pane"], req["all"]), ("queue", "list", 100, True))
        self.assertNotIn("target_pane", req)
        self.assertEqual(json.loads(out), [{"id": 11}])

        calls, _, _ = self._run_cli(["queue", "list", "105", "--cwd", "/tmp/x"], reply)
        self.assertEqual(calls[0]["target_pane"], 105)
        self.assertEqual(calls[0]["cwd"], str(Path("/tmp/x").resolve()))

        calls, _, _ = self._run_cli(["queue", "edit", "11", "--pane", "105", "-m", " new text "], reply)
        self.assertEqual((calls[0]["action"], calls[0]["id"], calls[0]["prompt"], calls[0]["target_pane"]), ("edit", 11, "new text", 105))

        calls, code, out = self._run_cli(
            ["queue", "move", "11", "--to", "1", "--to-pane", "106"],
            {"ok": True, "id": 11, "from_pane": 105, "to_pane": 106, "position": 1, "dispatched": True},
        )
        self.assertIsNone(code)
        self.assertTrue(json.loads(out)["dispatched"])
        self.assertEqual((calls[0]["action"], calls[0]["to_pos"], calls[0]["to_pane"]), ("move", 1, 106))
        self.assertNotIn("target_pane", calls[0])

        calls, _, _ = self._run_cli(["queue", "reorder", "--pane", "105", "12", "11"], reply)
        self.assertEqual((calls[0]["action"], calls[0]["ordered_ids"], calls[0]["target_pane"]), ("reorder", [12, 11], 105))

        calls, _, _ = self._run_cli(["queue", "reorder", "12", "11", "105"], reply)
        self.assertEqual(calls[0]["ordered_ids"], [12, 11, 105])
        self.assertTrue(calls[0]["allow_trailing_pane"])
        self.assertNotIn("target_pane", calls[0])

    def test_queue_cancel_positionals(self) -> None:
        reply = {"ok": True, "pane": 105, "cancelled": 1, "remaining": 0}
        calls, _, out = self._run_cli(["queue", "cancel", "11"], reply)
        self.assertEqual((calls[0]["id"], "target_pane" in calls[0]), (11, False))
        self.assertEqual(json.loads(out)["cancelled"], 1)
        calls, _, _ = self._run_cli(["queue", "cancel", "11", "105"], reply)
        self.assertEqual((calls[0]["id"], calls[0]["target_pane"]), (11, 105))
        calls, _, _ = self._run_cli(["queue", "cancel", "11", "--pane", "105"], reply)
        self.assertEqual(calls[0]["target_pane"], 105)
        calls, _, _ = self._run_cli(["queue", "cancel", "105", "--all"], reply)
        self.assertEqual((calls[0]["target_pane"], calls[0]["all"], "id" in calls[0]), (105, True, False))
        calls, _, _ = self._run_cli(["queue", "cancel", "105", "--position", "2"], reply)
        self.assertEqual((calls[0]["target_pane"], calls[0]["position"]), (105, 2))
        _, code, _ = self._run_cli(["queue", "cancel"], reply)
        self.assertIsInstance(code, str)
        _, code, _ = self._run_cli(["queue", "cancel", "--all", "--position", "1"], reply)
        self.assertIsInstance(code, str)

    def test_queue_cli_errors(self) -> None:
        calls, code, _ = self._run_cli(["queue", "edit", "11", "-m", "x"], {"ok": False, "error": "no such id"})
        self.assertEqual(code, "error: no such id")
        _, code, _ = self._run_cli(["queue", "move", "11"])
        self.assertIn("--to", str(code))
        _, code, _ = self._run_cli(["queue", "list", "100"])
        self.assertIn("own pane", str(code))

    def test_unqueue_by_id_routes_without_pane_and_send_position(self) -> None:
        calls, _, out = self._run_cli(["unqueue", "--id", "19"], {"ok": True, "pane": 106, "cancelled": 1, "remaining": 2})
        self.assertEqual([c["op"] for c in calls], ["unqueue"])
        self.assertEqual((calls[0]["id"], calls[0]["target_pane"]), (19, None))
        self.assertEqual(json.loads(out)["pane"], 106)
        req = self._dispatch(["same", "--position", "1"], _multi_status([105]))
        self.assertEqual(req["position"], 1)
        self.assertNotIn("position", self._dispatch(["same"], _multi_status([105])))

    def test_send_surfaces_queue_id_for_async_and_wait(self) -> None:
        import io
        from contextlib import redirect_stderr
        from unittest import mock

        queued = {"pane": 105, "queued": True, "position": 2, "queue_id": 42}
        with self._patched(_multi_status([105]), [], {"ok": True, "async_callback": True, **queued}):
            buf = io.StringIO()
            with mock_stdout(buf), self.assertRaises(SystemExit) as done:
                wingman.cmd_send(wingman.build_parser().parse_args(["send", "same", "-m", "go", "--async"]))
            self.assertEqual(done.exception.code, 0)
            self.assertIn("#2 id=42", buf.getvalue())

        def bridge(req, timeout=None, on_ack=None):
            if req["op"] == "status":
                return _multi_status([105])
            on_ack(queued)
            return {"ok": True, "last_message": "done"}

        buf = io.StringIO()
        with self._patched(_multi_status([105]), []), mock.patch.object(wingman, "call_bridge", bridge), redirect_stderr(buf):
            with self.assertRaises(SystemExit) as done:
                wingman.cmd_send(wingman.build_parser().parse_args(["send", "same", "-m", "go", "--wait"]))
        self.assertEqual(done.exception.code, 0)
        self.assertIn("#2 id=42", buf.getvalue())

    def test_info_fast_discovery_skips_session_work(self) -> None:
        import io
        from unittest import mock

        status = {"ok": True, "agents": [], "custom_agents": ["agy", "claude", "agy", "team.agent"]}
        for flags in (["--no-sessions"], ["--limit", "0"]):
            out = io.StringIO()
            with self.subTest(flags=flags), self._patched(status, []), mock_stdout(out):
                with mock.patch.object(wingman, "sessions_root", side_effect=AssertionError("session scan")), mock.patch.object(
                    wingman, "get_collab_hosts", side_effect=AssertionError("collab subprocess")
                ):
                    args = wingman.build_parser().parse_args(["info", *flags])
                    args.func(args)
                self.assertEqual(json.loads(out.getvalue())["availableAgents"], ["omp", "claude", "codex", "copilot", "agy", "team.agent"])
                self.assertEqual(json.loads(out.getvalue())["sessions"], [])

    def test_delivery_json_outcomes(self) -> None:
        import io

        scenarios = [
            ({"ok": True, "async_callback": True, "queued": True, "queue_id": 17, "position": 2}, 0,
             {"async": True, "queued": True, "queueId": 17, "position": 2}),
            ({"ok": True, "async_callback": True}, 0, {"async": True, "queued": False, "position": 0}),
            ({"ok": True, "status": "done", "last_message": "result"}, 0,
             {"async": False, "status": "done", "lastMessage": "result"}),
            ({"ok": False, "status": "waiting_input", "error": "approval needed"}, 2,
             {"status": "waiting_input", "error": "approval needed"}),
            ({"ok": False, "status": "failed", "error": "fault"}, 1, {"status": "failed", "error": "fault"}),
        ]
        for command in ("send", "retry"):
            for reply, code, fields in scenarios:
                if command == "retry" and reply.get("queued"):
                    continue
                argv = ["send", "same", "-m", "go"] if command == "send" else ["retry", "105"]
                with self.subTest(command=command, reply=reply), self._patched(_multi_status([105]), [], {**reply, "pane": 105}):
                    out = io.StringIO()
                    args = wingman.build_parser().parse_args([*argv, "--json", "--async" if reply.get("async_callback") else "--wait"])
                    with mock_stdout(out):
                        try:
                            args.func(args)
                        except SystemExit as exc:
                            self.assertEqual(exc.code, code)
                        else:
                            self.assertEqual(code, 0)
                    obj = json.loads(out.getvalue())
                    self.assertEqual((obj["ok"], obj["pane"]), (reply["ok"], 105))
                    self.assertEqual({key: obj[key] for key in fields}, fields)

    def test_transcript_char_cap_compacts_tool_text_first(self) -> None:
        messages = [{"role": "assistant", "text": "keep this summary", "tools": [{"name": "read", "text": 'λ\n"' * 2000}]}]
        _, code, out = self._run_cli(["transcript", "105", "--max-chars", "240"], {"ok": True, "messages": messages})
        self.assertIsNone(code)
        self.assertLessEqual(len(out.rstrip("\n")), 240)
        result = json.loads(out)
        self.assertEqual(result[0]["text"], "keep this summary")
        self.assertIn("… (truncated ", result[0]["tools"][0]["text"])

    def test_info_reports_queued_items(self) -> None:
        status = _multi_status([105])
        next(a for a in status["agents"] if a["pane"] == 105)["queued_items"] = [{"id": 11, "position": 1}]
        import io
        from unittest import mock

        buf = io.StringIO()
        ns = wingman.build_parser().parse_args(["info"])
        with self._patched(status, [], None), mock_stdout(buf), mock.patch.object(
            wingman, "find_ovnfs_bin", lambda: None
        ), mock.patch.object(wingman, "find_omp_bin", lambda required=True: None):
            ns.func(ns)
        agent = next(a for a in json.loads(buf.getvalue())["ternAgents"] if a["pane"] == 105)
        self.assertEqual(agent["queuedItems"], [{"id": 11, "position": 1}])

    def test_call_bridge_queued_reload_fails_instead_of_reattaching(self) -> None:
        from unittest import mock

        def run(ack: dict, frames_after: list) -> tuple[dict, list]:
            sent: list[dict] = []
            seq = iter([ack, *frames_after])

            class FakeSock:
                def __init__(self, *a, **k): ...
                def settimeout(self, _t): ...
                def connect(self, _a): ...
                def sendall(self, data): sent.append(json.loads(data))
                def close(self): ...

            with tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / "w-1.sock").write_text("")
                with mock.patch.object(wingman, "bridge_ipc_dir", lambda: Path(tmp)), mock.patch.object(
                    wingman.socket, "socket", FakeSock
                ), mock.patch.object(wingman, "_read_json_line", lambda *a, **k: next(seq)), mock.patch.object(
                    wingman.time, "sleep", lambda _s: None
                ):
                    return wingman.call_bridge({"op": "dispatch", "anchor_pane": 100}, timeout=5), sent

        reply, sent = run({"_ack": True, "pane": 105, "queued": True}, [{"_reload": True}])
        self.assertFalse(reply["ok"])
        self.assertEqual([s["op"] for s in sent], ["dispatch"])
        reply, sent = run({"_ack": True, "pane": 105, "queued": True}, [None])
        self.assertFalse(reply["ok"])
        self.assertEqual(len(sent), 1)
        # Non-queued ack still re-attaches via `await`
        reply, sent = run({"_ack": True, "pane": 105}, [{"_reload": True}, {"ok": True, "last_message": "done"}])
        self.assertTrue(reply["ok"])
        self.assertEqual([s["op"] for s in sent], ["dispatch", "await"])

    def test_luau_queue_fixture(self) -> None:
        import shutil

        luau = shutil.which("luau")
        if luau is None:
            self.skipTest("`luau` runner is not on PATH; cannot execute tests/queue_fixture.luau")
        fixture = ROOT_DIR / "tests" / "queue_fixture.luau"
        proc = subprocess.run([luau, str(fixture)], cwd=ROOT_DIR, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    def test_luau_subagents_fixture(self) -> None:
        import shutil

        luau = shutil.which("luau")
        if luau is None:
            self.skipTest("`luau` runner is not on PATH; cannot execute tests/subagents_fixture.luau")
        fixture = ROOT_DIR / "tests" / "subagents_fixture.luau"
        proc = subprocess.run([luau, str(fixture)], cwd=ROOT_DIR, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    def test_queue_id_actions_need_no_explicit_pane(self) -> None:
        reply = {"ok": True, "pane": 105, "cancelled": 1, "remaining": 0}
        calls, code, _ = self._run_cli(["queue", "edit", "11", "-m", "new"], reply)
        self.assertIsNone(code)
        self.assertEqual((calls[0]["op"], calls[0]["action"], calls[0]["id"]), ("queue", "edit", 11))
        self.assertNotIn("target_pane", calls[0])
        calls, code, _ = self._run_cli(["queue", "cancel", "11"], reply)
        self.assertIsNone(code)
        self.assertEqual((calls[0]["action"], calls[0]["id"]), ("cancel", 11))
        self.assertNotIn("target_pane", calls[0])

    def test_bound_transcript_water_filling_and_head_tail(self) -> None:
        huge_log = "BUILD_START " + ("x" * 2000) + " FATAL_ERROR_AT_TAIL"
        msgs = [
            {
                "role": "assistant",
                "text": "Summary ready.",
                "tools": [
                    {"name": "check", "text": "tests passed"},
                    {"name": "bash", "text": huge_log},
                ],
            }
        ]
        # 1. Compact JSON preserves everything without clipping when pretty > max_chars >= compact
        pretty_len = len(json.dumps(msgs, ensure_ascii=False, indent=2))
        compact_len = len(json.dumps(msgs, ensure_ascii=False, separators=(",", ":")))
        self.assertLess(compact_len, pretty_len)
        out_compact = wingman.bound_transcript_json(msgs, compact_len)
        self.assertLessEqual(len(out_compact), compact_len)
        self.assertEqual(json.loads(out_compact), msgs)

        # 2. Water-filling keeps short tool text & message text intact while clipping only huge_log with head+tail
        out = wingman.bound_transcript_json(msgs, 360)
        self.assertLessEqual(len(out), 360)
        parsed = json.loads(out)
        self.assertEqual(parsed[0]["text"], "Summary ready.")
        self.assertEqual(parsed[0]["tools"][0]["text"], "tests passed")
        clipped = parsed[0]["tools"][1]["text"]
        self.assertIn("BUILD_START", clipped)
        self.assertIn("FATAL_ERROR_AT_TAIL", clipped)
        self.assertIn("truncated", clipped)

        # 3. Minimum valid JSON boundary
        self.assertEqual(wingman.bound_transcript_json(msgs, 2), "[]")

    def test_luau_workbench_view_fixture(self) -> None:
        import shutil

        luau = shutil.which("luau")
        if luau is None:
            self.skipTest("`luau` runner is not on PATH; cannot execute tests/workbench_view_fixture.luau")
        fixture = ROOT_DIR / "tests" / "workbench_view_fixture.luau"
        proc = subprocess.run([luau, str(fixture)], cwd=ROOT_DIR, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    def test_luau_native_ui_fixture(self) -> None:
        import shutil

        luau = shutil.which("luau")
        if luau is None:
            self.skipTest("`luau` runner is not on PATH; cannot execute tests/native_ui_fixture.luau")
        fixture = ROOT_DIR / "tests" / "native_ui_fixture.luau"
        proc = subprocess.run([luau, str(fixture)], cwd=ROOT_DIR, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    def test_window_luau_ownership_fixture(self) -> None:
        import shutil

        luau = shutil.which("luau")
        if luau is None:
            self.skipTest("`luau` runner is not on PATH; cannot execute window.luau against tests/ownership_fixture.luau")
        fixture = (ROOT_DIR / "tests" / "ownership_fixture.luau").read_text(encoding="utf-8")
        window = (ROOT_DIR / "window.luau").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            for module in ("state.luau", "tsp.luau", "queue.luau"):
                shutil.copy(ROOT_DIR / module, Path(tmp) / module)
            script = Path(tmp) / "ownership_fixture_run.luau"
            script.write_text(fixture.replace("-- @WINDOW_PLUGIN@", window), encoding="utf-8")
            proc = subprocess.run([luau, str(script)], cwd=ROOT_DIR, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")


if __name__ == "__main__":
    unittest.main()
