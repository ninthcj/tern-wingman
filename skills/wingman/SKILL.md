---
name: wingman
description: >-
  Coordinate with a live side-pane or Picture-in-Picture `omp` wingman in Tern via native TSP (`WindowCx.agents`).
  Use when delegating substantial implementation, multi-file refactoring, test suites, or long execution runs to a
  side-pane worker, driving a worker split or PiP float in Tern, or running risky/parallel changes in `ovnfs`
  copy-on-write checkouts.
---

# Wingman (Native Tern TSP Side-Pane & PiP Worker Bridge)

Use the bundled [wingman.py](./scripts/wingman.py) script (resolved relative to this `SKILL.md` file) to drive a live `omp` wingman inside Tern when delegating work makes engineering sense (or when requested by the user); handle trivial one-off edits directly instead of spawning a worker unnecessarily.

## 1. Engineering Judgment: When & How to Delegate

Inspect current state (`wingman.py info --cwd <dir>`), then decide per task:

- **Direct vs. Delegated**: Delegate multi-file changes, refactors, test/fix loops, or long runs where parallel/side-pane execution shines, then review `git diff` / test results afterward; do tiny edits directly unless the user asks for wingman.
- **Session target (`new` | `same` | `latest` | `<sessionId>`)**:
  - **`new`**: Fresh session — use for independent tasks or whenever old session history would only add noise.
  - **`same`**: Continue in the active wingman pane already open in this tab (errors cleanly if none is open rather than guessing a file from disk).
  - **`<sessionId>` / `latest`**: Explicitly resume a persisted session seen in `info`.
- **Prompt & flags**:
  - Include clear goals, relevant architectural invariants, constraints, and verification criteria while omitting unrelated chat tangents. Remind unattended runs not to block on interactive `ask`.
  - Respect the user's configured `omp` defaults; pass `--model` or `--thinking` only when a specific override is warranted.
- **Copy-on-Write Sandbox (`ovnfs`)**:
  - When `ovnfsBin` is available, risky refactors or parallel A/B runs can use a zero-copy checkout: `ovnfs new <dir>` → `--cwd <checkout>` → `ovnfs diff <checkout>` → `ovnfs apply <checkout>` (or `ovnfs rm <checkout>`).

## 2. Primitives (`wingman.py`)

Inside Tern (`$TERN_PANE` set), `wingman.py` talks directly to `WindowCx.agents` over TSP (`cx.agents:start` / `cx.agents:ask` atomic send + `agent_finished` event wakeup — zero PTY paste emulation, zero `.jsonl` polling, zero focus stealing). Outside Tern (or with `--mode headless`), it runs `omp -p --wait-async`.

```bash
# Let WINGMAN_PY="<directory-of-this-SKILL.md>/scripts/wingman.py"

# 1. Inspect live Tern TSP agents, PiP floats, ovnfs availability, and recent sessions
python3 "$WINGMAN_PY" info --cwd /path/to/project

# 2. Dispatch work (explicitly choose `new`, `same`, or `<sessionId>`; optional `--pip br`, `--model`, `--thinking`)
python3 "$WINGMAN_PY" send <new|same|sessionId> \
  --cwd /path/to/project \
  --prompt-file /path/to/prompt.md

# 3. Read structured TSP chat messages & tool cards directly from Tern memory (or `peek` for mid-turn granularity)
python3 "$WINGMAN_PY" transcript --last 6
python3 "$WINGMAN_PY" peek latest --cwd /path/to/project

# 4. Float into Picture-in-Picture corner, dock back to split, interrupt, or stop
python3 "$WINGMAN_PY" pip --corner br
python3 "$WINGMAN_PY" dock --dir right
python3 "$WINGMAN_PY" interrupt
python3 "$WINGMAN_PY" stop
```

## Reference

For `WindowCx.agents` TSP bridge details, `ovnfs` workflows, Tern native blocks (`tern open --preview`, `tern browser`), and stateful RPC mode, read [internals.md](./references/internals.md).
