# Wingman Internals: Tern TSP Bridge, `ovnfs` & Worker Reference

## 1. Native `wingman` Tern Plugin (`WindowCx.agents` over TSP)

Installed in Tern (`tern plugin install github.com/ninthcj/tern-wingman`, plugin `id = "wingman"`):
- **Atomic TSP Delivery (`cx.agents:start` & `cx.agents:ask`)**: Delivers prompts through Tern's native TSP `send` event (queued until `sendable=true`), bypassing PTY line-discipline 4 KB buffers and keystroke emulation completely.
- **Event-Driven Completion**: Subscribes to `tern.on("agent_finished")` and `tern.on("agent_state")`, replying over authenticated `127.0.0.1` loopback HTTP the instant a turn settles or enters `waiting_input`, carrying `last_message` and `cx.agents:transcript()`.
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
