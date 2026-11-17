# Wingman Internals: Tern TSP Bridge, `ovnfs` & Worker Reference

## 1. Native `wingman` Tern Plugin (`WindowCx.agents` over TSP)

Installed in Tern (`tern plugin install github.com/ninthcj/tern-wingman`, plugin `id = "wingman"`):
- **Atomic TSP Delivery (`cx.agents:start` & `cx.agents:ask`)**: Delivers prompts through Tern's native TSP `send` event (queued until `sendable=true`), bypassing PTY line-discipline 4 KB buffers and keystroke emulation completely.
- **Event-Driven UNIX Socket Bus (`mux.py` via `tern.process.spawn`)**: Zero filesystem timer polling and zero ephemeral TCP ports; `window.luau` streams JSON-lines over a `0600` `AF_UNIX` socket with native UI VM wakeup (`1–5 ms` even when the Wayland window is occluded) and seamless hot-reload recovery (`_ack` / `_reload` -> `await`).
- **Explicit Ownership Graph (`bindings_v1` in `tern.kv`)**: Tracks `anchor_pane -> wingman_pane` bijectively so ACP lead agents (`agy`, `claude`, `codex`) never hit themselves or each other's workers, and `same` / `interrupt` / `pip` stay bound even across `ovnfs` checkouts or subdirectory changes.
- **Non-Intrusive Layout & PiP**: Preserves keyboard focus in the lead agent's pane even across tabs, and supports corner floating (`cx.layout:float`) and docking (`cx.layout:dock`).

## 2. Zero-Copy Checkouts (`ovnfs`)

When [ovnfs](https://github.com/stencil-hq/ovnfs) is installed:
- `ovnfs new <dir>` → instant Copy-on-Write checkout path without copying dependencies or build artifacts
- `ovnfs diff <checkout>` → inspect source changes against base
- `ovnfs apply <checkout>` → merge source changes back into `<dir>`
- `ovnfs rm <checkout>` → discard checkout cleanly

## 3. Tern Native Workspace Utilities

- `tern open --preview <file>:<line>` → open file at line in a side preview block without stealing focus
- `tern browser '{"op":"open","owner":<pane>,"url":"..."}'` → native WebKit (`abkit`) automation & DOM snapshots
- `omp read omp://` → embedded worker documentation (`omp://rpc.md`, `omp://collab.md`, `omp://cli-reference.md`)
