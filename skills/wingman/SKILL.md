---
name: wingman
description: >-
  Coordinate concurrent Tern agent wingmen (`omp` by default, or any Tern ACP agent such as `claude`,
  `codex`, `copilot`, or a custom one) over native TSP (`WindowCx.agents`).
  Use when delegating implementation, refactoring, tests, or execution to live workers, choosing
  native pane layouts, or working in `ovnfs` copy-on-write checkouts.
---

# Wingman

Drive a live Tern agent worker over native TSP (`WindowCx.agents`): `omp` by default, or any Tern agent via `--agent ID`. Outside Tern, only `omp` runs headless (`omp -p`).

**Invocation**: run `wingman <cmd> ...` if on `PATH`, otherwise `python3 <this-skill-dir>/scripts/wingman.py <cmd> ...`. The CLI reference below is complete—invoke directly without inspecting script source.

## CLI Reference

```bash
# Inspect live Tern agents, bindings, floats, ovnfs availability, and recent sessions
wingman info [--cwd DIR] [--limit 6 | --limit 0 | --no-sessions]   # fast: live state + availableAgents, no session scan

# Dispatch a prompt to a worker
#   target: new (ADDS a fresh worker) | same (bound/tab worker) | latest | <sessionId/path>
#   prompt: -m TEXT | --prompt TEXT | --prompt-file FILE (use '-' to pipe stdin)
wingman send <new|same|latest|sessionId> (-m TEXT | --prompt-file FILE|-) \
  [--agent ID] [--cwd DIR] [--pane ID] [--replace] [--layout split|down|pip|tab|park] \
  [--pip tl|tr|bl|br] [--model M] [--thinking L] [--max-time 30m] \
  [--mode auto|tui|headless] [--no-queue | --position N] [--async | --wait] \
  [--auto-callback | --no-auto-callback] [--takeover-idle] [--allow-fork] [--json]

# Pending tasks only; each action accepts [pane | --pane ID] and [--cwd DIR]
wingman queue list [--all]
wingman queue edit ID (-m TEXT | --prompt-file FILE|-)
wingman queue move ID [--to POS] [--to-pane PANE_ID]
wingman queue reorder ID [ID ...]
wingman queue cancel ID | --position POS | --all
wingman unqueue [--id ID | --position POS]

# Read structured TSP chat transcript from Tern memory, or tail-peek .jsonl
wingman transcript [pane | --pane ID] [--last 8] [--max-chars N] [--cwd DIR]
wingman peek [latest|sessionId] [--cwd DIR] [--bytes 65536] [--lines 25]

# Recover a worker stalled on `F5 to retry` via native `/retry`
wingman retry [pane | --pane ID] [--cwd DIR] [--async | --wait] [--max-time 30m] [--json]   # omp-style fault recovery

# Inspect & answer a worker blocked on `ask`/approval (`waiting_input`)
wingman surface [pane | --pane ID] [--cwd DIR] [--root NODE_ID] [--all] [--json]
wingman event [--pane ID] [--cwd DIR] [--no-rearm] '<json-event>' ...

# Layout & lifecycle (all accept optional [pane | --pane ID] [--cwd DIR])
wingman pip [--corner br|bl|tr|tl]
wingman dock [--dir right|left|up|down]
wingman park        # hide a worker (omp keeps running; hidden ACP agents queue prompts until unpark)
wingman unpark      # bring it back in the current tab, unfocused
wingman interrupt
wingman stop
wingman callback [status|on|off|reset] [--global] [--pane OWNER_ID]
```

- **Stale pane id** (closed/replaced worker): re-run `wingman info` (add `--no-sessions` for the fast path; it lists `availableAgents` and `boundWingmanPanes`) and retry with the current ID. Use `--json` on `send`/`retry` for machine-readable results and `transcript --max-chars N` to bound output.

## Agents (`--agent ID`)

- **Default `omp`**: unchanged. `--thinking`, `--takeover-idle`, `--allow-fork`, headless mode and `omp` session-path resume apply only here.
- **Any other Tern agent** (built-ins `claude`, `codex`, `copilot`, or a custom id): launched as `tern acp <id>`. Supported: `--model M`; a positional session ID (`wingman send <session-id> --agent claude …`) is passed as native `--resume <session-id>` (Wingman has no `--resume` flag); `latest` → native `--continue`; `new` → fresh session. Working directory comes from the pane layout `--cwd`.
- **Rejected for non-omp** (errors, never emulated): `--mode headless` (ACP needs Tern), `--thinking`, `--takeover-idle`, `--allow-fork`.
- `same` reuses/adopts a live bound worker whatever its agent; `--agent` matters only when launching. Adoption takes any live unowned agent in the same tab, preferring a cwd match.
- Custom ids must be lowercase letters/digits/`.`/`_`/`-`, ≤64 chars, no leading `-`. Custom agents must first be added in Tern **Settings › Agents** (id/name/command/args/env); they are not preinstalled.
- `info` reports each agent's `kind`; `omp` is detected only by its pane-file signal.
- **Hidden ACP agents** (Tern 0.9.30): a parked or background-tab ACP agent accepts a prompt but queues it until its pane is shown/unparked. Use `split`/`down`/`pip` in the current tab for unattended ACP work and callbacks; `unpark` before expecting queued ACP prompts/callbacks. `omp` keeps running and responding while parked.

## Runtime Behavior

- **Async default when the caller is a Tern agent** (e.g. `agy`, `claude`, `codex`, detected by the caller's ID in Tern's agent list): `send` and `retry` return immediately after dispatch and Tern submits `[Wingman auto-callback · pane <id>]` back into your composer when the worker finishes. Do not poll or sleep; pass `--wait` only to force blocking stdout. Workers report back simply by finishing their turn (or entering native `waiting_input` via their own interactive `ask` tool)—never instruct a worker to run a reverse CLI callback mid-turn.
- **Editable queue**: Busy workers queue prompts in Wingman and promote from the head on completion. `send --position N` inserts into a 1-based slot; otherwise it appends. Use the returned queue ID rather than the slot to edit, move, or cancel; promoted or removed IDs are rejected. `queue list --all` lists your workers' pending tasks in this window, and `reorder` requires every ID on one pane exactly once. Moving to an idle worker can dispatch immediately. Pending prompts do not survive plugin reload.
- **`[Wingman waiting_input · pane <id>]`**: `send` onto a `waiting_input` pane is refused. Inspect with `surface`, answer with `event` (auto-rearms callback unless `--no-rearm`; simple option pick: `'{"ev":"action","id":"ui","act":"pick:0:0"}' '{"ev":"action","id":"ui.actions/submit","act":"submit"}'`). Decide technical/architectural questions yourself; consult the user on product/scope/cost trade-offs.
- **`[Wingman fault · retryable · pane <id>]`**: worker exhausted internal recovery and is waiting on `F5 to retry`. Run `retry --pane <id>` for transient stream/network/edit-preview glitches (up to 2–3 tries); consult the user on persistent quota/auth/config errors.
- **1-to-N and multi-level**: `send new` adds a worker; `send new --replace` stops only the selected bound worker before launching a fresh one. `info` lists `boundWingmanPanes`. With one worker, `send same` and controls select it automatically. With several, pass `--pane ID` or an explicit `--cwd DIR` matching exactly one; ambiguity errors list the bound IDs. Workers may themselves own wingmen (nested trees); explicitly binding a pane to itself or an ancestor is rejected with a cycle error before any effect, leaving the graph unchanged.
- **Zero-copy checkouts**: when `ovnfsBin` is present in `info`, use `ovnfs new|diff|apply|rm`.

## Layout Selection

- **One primary interactive task:** `split` beside the supervisor (the default).
- **Quick check or peripheral watcher:** `pip`. `--pip tl|tr|bl|br` implies `--layout pip` and pins that corner; omitting the corner picks the first free corner (`br → tr → bl → tl`).
- **Second concurrent worker:** `down` stacks below the right-side worker (or below the supervisor if none), or use `pip`.
- **Three or more workers, or heavy/noisy `omp` runs:** `park` keeps `omp` workers off-screen but live, with callbacks and Live Panel visibility. Use `tab` for a dedicated background tab (ACP agents there queue until shown). `unpark` brings a parked worker back into the current tab without focusing it.

## Workbench

**Wingman Live** works with one standalone Tern agent or a whole ownership tree. The panel provides Living Files, Subagent Panes, PiP/Park, and queue controls. Use **Wingman: Queue Prompt for Agent** or the row’s **+** in Tern; from an agent turn, prefer the CLI.

## On-Demand References (read only when needed)

- `references/interactive.md`: multi-step TSP `event` JSON recipes for filling free-text `Other…` inputs or attaching option `Note`s.
- `references/internals.md`: Tern plugin architecture, `ovnfs` workflow, and Tern native workspace blocks.
