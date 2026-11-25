---
name: wingman
description: Delegate to Tern agents, answer blocked workers, manage queues and layouts, and use ovnfs checkouts.
---

# Wingman

Run `wingman` from Tern, or use `python3 <skill-dir>/scripts/wingman.py` if it isn't on PATH.

## Delegate and inspect

```bash
wingman info [--all] [--sessions] [--limit N] [--cwd DIR]
wingman send <new|same|latest|sessionId> (-m TEXT | --prompt-file FILE|-) \
  [--agent ID] [--cwd DIR] [--pane ID] [--replace] [--model M] [--thinking LEVEL] \
  [--layout split|down|pip|tab|park] [--pip tl|tr|bl|br] \
  [--async | --wait] [--max-time 30m] [--position N | --no-queue] [--json]
wingman transcript [--pane ID] [--last 6] [--max-chars 8000] [--tools | --full]
wingman retry [--pane ID] [--async | --wait] [--max-time 30m] [--json]
```

- `info` shows your workers, owner, and unclaimed peers in your tab. Use `--all` for the window and `--sessions` for history. Pick an ID from `availableAgents` (`omp` is the default).
- `send new` adds a worker; `--replace` replaces only the targeted worker. `send same` reuses a worker. If several match, pass `--pane ID` or an explicit `--cwd DIR`. Outside Tern, only `omp` runs headless.
- `info` reports `context` and `thinking` for `omp` workers. If a worker stops mid-scope or you’re considering `--replace`, check `info` first. If `thinking` dropped to `low` and `context` has headroom, continue with `send same --thinking high` to keep the warm cache. Reserve `--replace` for saturated context or unrelated work.
- Agent callers are async by default. Continue when the callback arrives; don't poll. Workers report back automatically when their turn ends or enters `waiting_input`—never instruct a worker to run a reverse `wingman` callback mid-turn. Use `--wait` only when you need the result on stdout.
- `transcript` defaults to compact messages and tool summaries. Use `--tools` for tool output or `--full` for the raw transcript.

## Reply to a blocked worker

Use the choices in `[Wingman waiting_input]`. Numbers select options in question order, not pane IDs. Decide technical/implementation questions yourself; consult the user on product, scope, or cost trade-offs.

```bash
wingman answer 2 --pane ID
wingman answer 1 3 --pane ID
wingman answer --question 2 --other "Custom answer" --pane ID
wingman answer --approve --pane ID  # or --deny / --cancel
```

Use `retry` for a transient `[Wingman fault]`. For unsupported cards or custom actions, see [interactive debugging](references/interactive.md).

## Manage queued prompts

```bash
wingman queue list [--all]
wingman queue edit ID (-m TEXT | --prompt-file FILE|-)
wingman queue move ID [--to POS] [--to-pane PANE_ID]
wingman queue reorder ID [ID ...]
wingman queue cancel [ID | --position POS | --all]
```

Queue commands accept `--pane ID` or `--cwd DIR`. Use stable queue IDs to edit pending prompts; `send --position N` inserts at a 1-based slot.

## Layouts and isolation

- `split` places the worker beside you; `down` stacks it; `pip` floats it; `tab` opens a separate tab; `park` hides it. Keep unattended ACP workers visible so queued prompts can start.
- Use `pip`, `dock`, `park`, `unpark`, `interrupt`, or `stop` with `--pane ID` to control an existing worker.
- For isolated changes, use `ovnfs new --name NAME` when `info` reports `ovnfsBin`. Review `ovnfs diff NAME` before `ovnfs apply NAME` or `ovnfs rm NAME`.
