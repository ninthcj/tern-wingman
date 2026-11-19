---
name: wingman
description: >-
  Coordinate with a live side-pane or Picture-in-Picture `omp` wingman in Tern via native TSP (`WindowCx.agents`).
  Use when delegating implementation, refactoring, test suites, or execution runs to a side-pane worker, driving a
  worker split or PiP float in Tern, or running changes in `ovnfs` copy-on-write checkouts.
---

# Wingman

Drive a live `omp` worker in Tern over native TSP (`WindowCx.agents`) or headless `omp -p` outside Tern.

**Invocation**: run `wingman <cmd> ...` if on `PATH`, otherwise `python3 <this-skill-dir>/scripts/wingman.py <cmd> ...`. The CLI reference below is complete—invoke directly without inspecting script source.

## CLI Reference

```bash
# Inspect live Tern agents, bindings, floats, ovnfs availability, and recent sessions
wingman info [--cwd DIR] [--limit 6]

# Dispatch a prompt to a worker
#   target: new (fresh session) | same (bound/tab worker) | latest | <sessionId/path>
#   prompt: -m TEXT | --prompt TEXT | --prompt-file FILE (use '-' to pipe stdin)
wingman send <new|same|latest|sessionId> (-m TEXT | --prompt-file FILE|-) \
  [--cwd DIR] [--pip tl|tr|bl|br] [--model M] [--thinking L] [--max-time 30m] \
  [--mode auto|tui|headless] [--no-queue] [--async | --wait] \
  [--auto-callback | --no-auto-callback] [--takeover-idle] [--allow-fork]

# Read structured TSP chat transcript from Tern memory, or tail-peek .jsonl
wingman transcript [pane | --pane ID] [--last 8] [--cwd DIR]
wingman peek [latest|sessionId] [--cwd DIR] [--bytes 65536] [--lines 25]

# Recover a worker stalled on `F5 to retry` via native `/retry`
wingman retry [pane | --pane ID] [--cwd DIR] [--async | --wait] [--max-time 30m]

# Inspect & answer a worker blocked on `ask`/approval (`waiting_input`)
wingman surface [pane | --pane ID] [--cwd DIR] [--root NODE_ID] [--all] [--json]
wingman event [--pane ID] [--cwd DIR] [--no-rearm] '<json-event>' ...

# Worker -> supervisor reverse push (run from inside the worker pane)
wingman report (-m TEXT | --prompt-file FILE|-) [--kind final|progress|question] [--pane OWNER_ID]

# Layout & lifecycle (all accept optional [pane | --pane ID] [--cwd DIR])
wingman pip [--corner br|bl|tr|tl]
wingman dock [--dir right|left|up|down]
wingman interrupt
wingman unqueue [--position N]
wingman stop
wingman callback [status|on|off|reset] [--global] [--pane OWNER_ID]
```

## Runtime Behavior

- **Async default in Tern ACP panes** (`agy`, `claude`, `codex`): `send` and `retry` return immediately after dispatch and Tern submits `[Wingman auto-callback · pane <id>]` back into your composer when the worker finishes. Do not poll or sleep; pass `--wait` only to force blocking stdout.
- **Native queueing**: `send same` while the worker is `working` queues inside Tern and promotes automatically on finish (`--no-queue` fails fast; `unqueue` cancels).
- **`[Wingman waiting_input · pane <id>]`**: `send` onto a `waiting_input` pane is refused. Inspect with `surface`, answer with `event` (auto-rearms callback unless `--no-rearm`; simple option pick: `'{"ev":"action","id":"ui","act":"pick:0:0"}' '{"ev":"action","id":"ui.actions/submit","act":"submit"}'`). Decide technical/architectural questions yourself; consult the user on product/scope/cost trade-offs.
- **`[Wingman fault · retryable · pane <id>]`**: worker exhausted internal recovery and is waiting on `F5 to retry`. Run `retry --pane <id>` for transient stream/network/edit-preview glitches (up to 2–3 tries); consult the user on persistent quota/auth/config errors.
- **Zero-copy checkouts**: when `ovnfsBin` is present in `info`, use `ovnfs new|diff|apply|rm`.

## On-Demand References (read only when needed)

- `references/interactive.md`: multi-step TSP `event` JSON recipes for filling free-text `Other…` inputs or attaching option `Note`s.
- `references/internals.md`: Tern plugin architecture, `ovnfs` workflow, and Tern native workspace blocks.
