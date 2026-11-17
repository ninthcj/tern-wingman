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
        for sub in ("interrupt", "stop", "pip", "dock", "transcript"):
            ns = parser.parse_args([sub, "--cwd", "/tmp/demo-repo"])
            self.assertEqual(ns.cwd, "/tmp/demo-repo")
        ns_send = parser.parse_args(["send", "same", "--prompt", "hi", "--no-queue"])
        self.assertTrue(ns_send.no_queue)
        ns_send_def = parser.parse_args(["send", "same", "--prompt", "hi"])
        self.assertFalse(ns_send_def.no_queue)

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
