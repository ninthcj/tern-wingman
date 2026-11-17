---
name: wingman
description: >-
  Act as lead architect/supervisor and delegate implementation, refactoring, test runs, and heavy execution
  work to a live side-pane or Picture-in-Picture `omp` wingman in Tern via native TSP (`WindowCx.agents`).
  Use whenever delegating coding or execution tasks to a side-pane worker, driving a worker split or PiP
  float in Tern, using `ovnfs` copy-on-write checkouts, or supervising multi-step implementation work.
---

# Wingman (Native Tern TSP Side-Pane & PiP Worker Bridge)

You lead architecture, planning, and verification (`git diff` / test review); delegate implementation and heavy execution runs to the side-pane `omp` wingman via the bundled [wingman.py](./scripts/wingman.py) script (resolve its path relative to this `SKILL.md` file).

## 1. Engineering Judgment: Session, Context & Workspace Curation

Inspect active state first (`wingman.py info --cwd <dir>`), then exercise judgment based on the task:

- **Session target (`new` | `same` | `<sessionId>`)**:
  - Choose **`new`** when starting an independent workstream or when an older session's accumulated history would add noise.
  - Choose **`same`** (or `<sessionId>`) when iterating on the same workstream where prior context genuinely saves work.
- **Prompt curation**:
  - Pass what helps the wingman do strong engineering work on *this* task — clear goals, relevant architectural invariants, constraints, and verification criteria — while leaving out unrelated chat tangents. Remind unattended runs not to block on interactive `ask`.
- **Copy-on-Write Sandbox (`ovnfs`) for risky/parallel work**:
  - When `ovnfs` is available (`ovnfsBin` in `info`), risky refactors or parallel A/B experiments can run in a zero-copy checkout: `ovnfs new <dir>` → run wingman with `--cwd <checkout>` → review via `ovnfs diff <checkout>` → merge via `ovnfs apply <checkout>` (or discard via `ovnfs rm <checkout>`).

## 2. Native Primitives (`wingman.py`)

Inside Tern (`$TERN_PANE` set), `wingman.py` talks directly to Tern's `WindowCx.agents` engine over TSP (`cx.agents:start` / `cx.agents:ask` atomic send + `agent_finished` event wakeup — zero PTY paste hacks, zero `.jsonl` polling, zero focus stealing). Outside Tern (or with `--mode headless`), it falls back to `omp -p --wait-async`.

```bash
# Let WINGMAN_PY="<directory-of-this-SKILL.md>/scripts/wingman.py"

# 1. Inspect live Tern TSP agents, PiP floats, ovnfs availability, and recent sessions
python3 "$WINGMAN_PY" info --cwd /path/to/project

# 2. Dispatch work (`new`, `same`, or `<sessionId>`; pass `--pip br` for Picture-in-Picture; background long runs)
python3 "$WINGMAN_PY" send <new|same|sessionId> \
  --cwd /path/to/project \
  --thinking high \
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
