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
        # Even though bound pane 105 has a different cwd (ovnfs checkout), `same` & `new` & `interrupt` target 105
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, lead_cwd, "same", None, anchor_pane=100),
            (105, False),
        )
        self.assertEqual(
            wingman.resolve_target_pane_from_status(status, None, lead_cwd, "new", None, anchor_pane=100),
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
        parser = wingman.build_parser()
        for sub in ("interrupt", "unqueue", "stop", "pip", "dock", "transcript"):
            ns = parser.parse_args([sub, "--cwd", "/tmp/demo-repo"])
            self.assertEqual(ns.cwd, "/tmp/demo-repo")
        ns_unq = parser.parse_args(["unqueue", "--position", "2"])
        self.assertEqual(ns_unq.position, 2)
        ns_send = parser.parse_args(["send", "same", "--prompt", "hi", "--no-queue"])
        self.assertTrue(ns_send.no_queue)
        self.assertIsNone(ns_send.auto_callback)
        ns_send_cb_off = parser.parse_args(["send", "same", "--prompt", "hi", "--no-auto-callback"])
        self.assertFalse(ns_send_cb_off.auto_callback)
        ns_send_cb_on = parser.parse_args(["send", "same", "--prompt", "hi", "--auto-callback"])
        self.assertTrue(ns_send_cb_on.auto_callback)
        ns_rep = parser.parse_args(["report", "-m", "done!", "--kind", "progress", "--pane", "100"])
        self.assertEqual(ns_rep.prompt, "done!")
        self.assertEqual(ns_rep.kind, "progress")
        self.assertEqual(ns_rep.pane, "100")
        ns_cb = parser.parse_args(["callback", "off", "--global"])
        self.assertEqual(ns_cb.mode, "off")
        self.assertTrue(ns_cb.global_scope)

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


if __name__ == "__main__":
    unittest.main()
