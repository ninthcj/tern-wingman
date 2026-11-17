---
name: wingman
description: >-
  Coordinate with a live side-pane or Picture-in-Picture `omp` wingman in Tern via native TSP (`WindowCx.agents`).
  Use when delegating implementation, refactoring, test suites, or execution runs to a side-pane worker, driving a
  worker split or PiP float in Tern, or running changes in `ovnfs` copy-on-write checkouts.
---

# Wingman (Native Tern TSP Side-Pane & PiP Bridge)

[wingman.py](./scripts/wingman.py) (resolve path relative to this `SKILL.md`) drives a live `omp` wingman inside Tern via `WindowCx.agents` over TSP (`cx.agents:start` / `cx.agents:ask` atomic send + `agent_finished` event wakeup — no PTY paste emulation, no `.jsonl` polling, no focus stealing). Outside Tern (or with `--mode headless`), it runs `omp -p --wait-async`.

## Commands

```bash
# Let WINGMAN_PY="<directory-of-this-SKILL.md>/scripts/wingman.py"

# Inspect live Tern TSP agents, PiP floats, ovnfs availability, and persisted sessions
python3 "$WINGMAN_PY" info --cwd /path/to/project

# Dispatch a prompt
# Target argument:
#   new          -> fresh session
#   same         -> active wingman pane in the current tab
#   <sessionId>  -> persisted session by ID/path (or `latest`)
python3 "$WINGMAN_PY" send <new|same|sessionId> \
  --cwd /path/to/project \
  --prompt-file /path/to/prompt.md

# Read structured TSP chat messages & tool cards from Tern memory, or tail-peek .jsonl
python3 "$WINGMAN_PY" transcript --last 6
python3 "$WINGMAN_PY" peek [latest|sessionId] --cwd /path/to/project

# Layout & lifecycle controls
python3 "$WINGMAN_PY" pip --corner br
python3 "$WINGMAN_PY" dock --dir right
python3 "$WINGMAN_PY" interrupt
python3 "$WINGMAN_PY" unqueue [--position 1]
python3 "$WINGMAN_PY" stop
```

## Notes

- Interactive `ask` calls inside `omp` pause the turn with `waiting_input` (exit code `2`) until answered by the user.
- Calling `send same` while the wingman pane is `working` natively queues the prompt inside Tern's `window.luau` and promotes it automatically on `agent_finished` (pass `--no-queue` to fail fast instead).
- When `ovnfsBin` is present in `info`, zero-copy Copy-on-Write checkouts are available via `ovnfs new <dir>`, `ovnfs diff <checkout>`, `ovnfs apply <checkout>`, and `ovnfs rm <checkout>`.
- For TSP bridge details, Tern native blocks (`tern open --preview`, `tern browser`), and stateful RPC mode, see [internals.md](./references/internals.md).
