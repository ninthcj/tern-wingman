from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "skills" / "wingman" / "scripts" / "wingman.py"
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

    def test_resolve_target_pane_from_status(self) -> None:
        cwd = Path("/tmp/demo-repo")
        status = {
            "agents": [
                {"pane": 101, "same_tab": True, "cwd": str(cwd), "state": "idle"},
                {"pane": 202, "same_tab": False, "cwd": "/tmp/other", "state": "idle"},
            ]
        }
        pane, reset_new = wingman.resolve_target_pane_from_status(status, None, cwd, "same", None)
        self.assertEqual((pane, reset_new), (101, False))

        pane_new, reset_new2 = wingman.resolve_target_pane_from_status(status, None, cwd, "new", None)
        self.assertEqual((pane_new, reset_new2), (101, True))

        pane_none, reset_none = wingman.resolve_target_pane_from_status({"agents": []}, None, cwd, "same", None)
        self.assertEqual((pane_none, reset_none), (None, False))

    def test_call_bridge_loopback_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            old_xdg = os.environ.get("XDG_RUNTIME_DIR")
            os.environ["XDG_RUNTIME_DIR"] = tmp
            try:
                ipc_dir = Path(tmp) / "tern-wingman"

                def mock_window_luau() -> None:
                    deadline = time.monotonic() + 3.0
                    while time.monotonic() < deadline:
                        if ipc_dir.is_dir():
                            for p in ipc_dir.iterdir():
                                if p.name.startswith(".") or p.suffix != ".json":
                                    continue
                                req = json.loads(p.read_text(encoding="utf-8"))
                                p.unlink(missing_ok=True)
                                body = json.dumps({"ok": True, "echo_op": req["op"], "agents": []}).encode("utf-8")
                                http_req = urllib.request.Request(
                                    f"http://127.0.0.1:{req['port']}/reply",
                                    data=body,
                                    method="POST",
                                    headers={
                                        "Authorization": f"Bearer {req['token']}",
                                        "Content-Type": "application/json",
                                    },
                                )
                                urllib.request.urlopen(http_req, timeout=2.0).read()
                                return
                        time.sleep(0.03)

                t = threading.Thread(target=mock_window_luau, daemon=True)
                t.start()
                reply = wingman.call_bridge({"op": "status", "anchor_pane": 42}, timeout=3.0)
                self.assertTrue(reply["ok"])
                self.assertEqual(reply["echo_op"], "status")
            finally:
                if old_xdg is None:
                    os.environ.pop("XDG_RUNTIME_DIR", None)
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old_xdg


if __name__ == "__main__":
    unittest.main()
