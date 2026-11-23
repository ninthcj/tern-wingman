# Wingman Internals: Tern TSP Bridge, `ovnfs` & Worker Reference

## 1. Native `wingman` Tern Plugin (`WindowCx.agents` over TSP)

Installed in Tern (`tern plugin install github.com/ninthcj/tern-wingman`, plugin `id = "wingman"`, split into acyclic Luau modules: `window.luau`, `state.luau`, `queue.luau`, `tsp.luau`, `radar.luau`, `radar_view.luau`, `subagents.luau`, `subagents_view.luau`):
- **Atomic TSP Delivery (`cx.agents:start` & `cx.agents:ask`)**: Delivers prompts through Tern's native TSP `send` event (queued until `sendable=true`), bypassing PTY line-discipline 4 KB buffers and keystroke emulation completely.
- **Event-Driven UNIX Socket Bus (`mux.py` via `tern.process.spawn`)**: Zero filesystem timer polling and zero ephemeral TCP ports; `window.luau` streams JSON-lines over a `0600` `AF_UNIX` socket with native UI VM wakeup (`1–5 ms` even when the Wayland window is occluded) and seamless hot-reload recovery (`_ack` / `_reload` -> `await`).
- **1-to-N Ownership Graph (`owners_v1` in `tern.kv`, migrated from `bindings_v1`)**: Managed by `state.luau`; tracks one supervisor owning many wingmen and multi-level delegation trees so Tern lead agents (`agy`, `claude`, `codex`) never hit themselves or each other's workers. Explicit binding to self or an ancestor is rejected with a cycle error before any side effect, and `same` / `interrupt` / `pip` stay bound even across `ovnfs` checkouts or subdirectory changes.
- **Bidirectional Callback, Escalations & Reverse Reporting (`report` + `auto_callback_v1`)**: Tracks unsolicited turns on bound workers (e.g. `omp` internal background jobs triggering follow-up turns after the supervisor went `idle`) and delivers completion summaries back to `boundOwner` via `cx.agents:ask` (coalescing in `queued_callbacks` if busy, with an explicit UTF-8-safe truncation notice past 3,600 bytes pointing to `wingman transcript --pane <id> --last 2`). `tsp.luau` extracts clean `waiting_input` summaries including native ACP `layer` dialogs. Workers can push mid-turn progress or final reports explicitly with `wingman report -m "..."` (or `-m -` for piped stdin).
- **Non-Intrusive Dynamic Layouts, PiP & Live Panel**: Preserves keyboard focus in the lead agent's pane even across tabs. Supports `split`, `down`, `pip`, `tab`, and `park`/`unpark` (returning beside the owner without splitting a focused Live Panel); additional `split`/`dock` workers stack cleanly in the right column (`tiled_slot`); `pip` scales dynamically from the owner's tab share and auto-selects the first free corner (`br → tr → bl → tl`). `radar.luau` + `radar_view.luau` render the native Wingman Live panel with remembered `sidebar_share`, proportional floating size, dynamic Living Files / activity budgets, and a strict 50 ms Lua hook guard.

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
