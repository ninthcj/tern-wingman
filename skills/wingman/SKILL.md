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

# Answer a worker blocked on `ask`/approval (`waiting_input`) via native TSP
python3 "$WINGMAN_PY" surface --pane <id> [--json] [--all] [--root <nodeId>]
# 1) Pick option(s) & submit (`pick:<fieldIdx>:<optIdx>` works even on folded fields; toggles checkboxes):
python3 "$WINGMAN_PY" event --pane <id> '{"ev":"action","id":"ui","act":"pick:0:0"}' '{"ev":"action","id":"ui.actions/submit","act":"submit"}'
# 2) Fill free-text `Other…` (or text `<input>`/`<textarea>`): open field -> select `other` -> inspect `<input_id>` via `surface` -> `edit` (UTF-16 lengths):
python3 "$WINGMAN_PY" event --pane <id> --no-rearm '{"ev":"action","id":"ui","act":"open:1"}'
python3 "$WINGMAN_PY" event --pane <id> --no-rearm '{"ev":"select","id":"ui.body/g1/q1/f1","item":"other"}'
python3 "$WINGMAN_PY" event --pane <id> '{"ev":"edit","id":"<input_id>","from":0,"to":0,"text":"Custom answer","cursor":13,"len":0}' '{"ev":"action","id":"ui.actions/submit","act":"submit"}'
# 3) Attach an option `Note`: open field -> `act:"note"` on option item -> inspect `<editor_id>` via `surface` -> `edit` + `save-note`:
python3 "$WINGMAN_PY" event --pane <id> --no-rearm '{"ev":"action","id":"ui.body/g0/q0/f0/o0","act":"note"}'
python3 "$WINGMAN_PY" event --pane <id> --no-rearm '{"ev":"edit","id":"<editor_id>","from":0,"to":0,"text":"Extra constraint","cursor":16,"len":0}' '{"ev":"action","id":"ui.actions/save-note","act":"save-note"}'

# Layout, bidirectional reporting & lifecycle controls
python3 "$WINGMAN_PY" report --prompt "Summary or question for bound supervisor" [--kind final|progress|question]
python3 "$WINGMAN_PY" callback [status|on|off|reset] [--global]
python3 "$WINGMAN_PY" pip --corner br
python3 "$WINGMAN_PY" dock --dir right
python3 "$WINGMAN_PY" interrupt
python3 "$WINGMAN_PY" unqueue [--position 1]
python3 "$WINGMAN_PY" stop
```

## Notes

- **`waiting_input` escalation**: when a bound `omp` worker hits an `ask` card/approval/hook prompt, the supervisor receives `[Wingman waiting_input · pane <id>]` with the card text, its TSP node ids, and usage hints (deduped per card). `send` to a `waiting_input` pane is refused; inspect with `surface`, answer or cancel with `event` (auto-callback re-arms for the resumed turn unless `--no-rearm`). Decide technical/architectural questions yourself; consult the user first on product/scope/cost trade-offs.
- Calling `send same` while the wingman pane is `working` natively queues the prompt inside Tern's `window.luau` and promotes it automatically on `agent_finished` (pass `--no-queue` to fail fast instead).
- **ACP UI Sync & Bidirectional Push (`--async` default for ACP callers)**:
  - When called from a Tern ACP pane (`agy`, `claude`, `codex`), `send` automatically returns immediately after dispatching/queueing (`async ACP callback` mode; pass `--wait` only to force blocking stdout wait). When `omp` finishes, `window.luau` submits `[Wingman auto-callback · pane <id>]` directly into the supervisor's composer via `cx.agents:ask` (`session/prompt`), keeping Tern's live chat UI 100% synchronized instead of running inside an unrendered background bash wakeup.
  - **Proactive `report`**: From inside the wingman pane, run `wingman.py report -m "..."` (`--kind progress` for mid-turn updates, `--kind final` or `question` for completion/escalation) to push directly up to `boundOwner` without blocking.
- When `ovnfsBin` is present in `info`, zero-copy Copy-on-Write checkouts are available via `ovnfs new <dir>`, `ovnfs diff <checkout>`, `ovnfs apply <checkout>`, and `ovnfs rm <checkout>`.
- For TSP bridge details, Tern native blocks (`tern open --preview`, `tern browser`), and stateful RPC mode, see [internals.md](./references/internals.md).
