# tern-wingman

<p align="center">
  <b>Fly with a live side-pane or Picture-in-Picture <code>omp</code> wingman inside <a href="https://stencil.so/tern">Tern</a>.</b><br>
  Native <code>WindowCx.agents</code> TSP bridge + portable agent skill for Antigravity, Claude Code, Codex, Gemini CLI, OpenCode &amp; more.
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/Tern-0.9%2B-blueviolet" alt="Tern 0.9+">
  <img src="https://img.shields.io/badge/Luau-window%20plugin-orange" alt="Luau plugin">
  <img src="https://img.shields.io/badge/Python-3.10%2B%20(stdlib)-green" alt="Python 3.10+">
</p>

---

**`tern-wingman`** lets any coding agent running inside a [Tern](https://stencil.so/tern) pane act as lead architect/supervisor while delegating implementation, refactoring, and heavy test runs to a live **[oh-my-pi (`omp`)](https://github.com/can1357/oh-my-pi)** wingman right beside it — or floating in a Picture-in-Picture corner.

Instead of emulating terminal keystrokes (`paste` + `Enter`, which breaks across 4 KB PTY buffers and steals focus) or polling multi-hundred-MB `.jsonl` logs on disk, `tern-wingman` drives Tern's own **`WindowCx.agents`** engine over the **Tern Surface Protocol (TSP)**:

- **Atomic TSP prompt delivery (`cx.agents:start` / `cx.agents:ask`)** — prompts are queued natively by Tern until `omp` reports `sendable=true` and delivered as a single atomic TSP `send` event, regardless of length.
- **Zero-polling `AF_UNIX` event bus (`tern.process.spawn` + `agent_finished`)** — zero `.jsonl` polling, zero timer directory scans, and zero ephemeral TCP ports; `window.luau` wakes `wingman.py` over a `0600` UNIX domain socket in `2–10 ms` (even when occluded on Wayland) and survives live `tern plugin reload`.
- **Explicit `anchor → wingman` ownership graph & FIFO queueing** — ACP lead agents (`agy`, `claude`, `codex`) never target themselves or collide in multi-agent tabs; sending to a busy worker queues natively in `window.luau` (`unqueue` cancels pending slots), and `same` / `interrupt` / `pip` track the bound worker across `ovnfs` checkouts and subdirectory changes.
- **Full-duplex bidirectional callbacks (`report` + Auto-Callback)** — if `omp` finishes an unsolicited follow-up turn (such as an internal background job completing after the lead agent went `idle`), `window.luau` automatically pushes the completion back into the lead agent's composer (coalescing if the lead agent is busy); `omp` can also push mid-turn progress or questions proactively via `wingman.py report`.
- **In-memory structured transcripts (`cx.agents:transcript`)** — read recent turns and tool cards straight from Tern's live TSP memory without touching disk.
- **Non-intrusive Splits & Picture-in-Picture (`--pip br`)** — spawns splits without yanking keyboard focus away from your lead agent (even across background tabs), and floats/docks the wingman as a corner PiP overlay on demand.
- **Mechanism, not policy** — zero prompt rewriting and zero hidden config overrides; the lead agent decides per task whether to open a fresh session (`new`), iterate in place (`same`), resume a specific session, or isolate risky changes in an [`ovnfs`](https://github.com/stencil-hq/ovnfs) copy-on-write checkout.

## Architecture

```mermaid
sequenceDiagram
    participant L as Lead Agent (ACP agy / claude / codex / …)
    participant W as wingman.py (AF_UNIX client)
    participant M as mux.py (0600 AF_UNIX <-> stdio)
    participant P as Tern Plugin (window.luau · WindowCx.agents)
    participant O as omp Wingman (Right Split or PiP)

    L->>W: wingman.py send <new|same|id> --prompt-file spec.md
    W->>M: JSON line over w-<pid>.sock
    M->>P: native stdout wakeup on UI VM thread
    P->>O: cx.agents:start / cx.agents:ask + bind(anchor -> wingman)
    P-->>W: {"_ack": true, "pane": ...}
    O-->>P: tern.on("agent_finished" | "agent_state")
    P->>M: child:write(last_message + TSP transcript)
    M->>W: JSON reply + EOF
    W-->>L: stdout reply + exit status (0=done, 2=waiting_input)
```

## Install

Both halves install directly from the repository root:

```sh
# 1. Install the Tern window plugin (hot-loads immediately)
tern plugin install github.com/ninthcj/tern-wingman

# 2. Install the agent skill (Claude Code, Cursor, Codex, OpenCode, Goose, …)
npx skills add ninthcj/tern-wingman
```

<details>
<summary><b>Manual / Antigravity / Local checkout setup</b></summary>

```sh
git clone https://github.com/ninthcj/tern-wingman.git
tern plugin link ./tern-wingman

# Symlink into Antigravity's or ~/.agents' skills folder:
ln -s "$(pwd)/tern-wingman/skills/wingman" ~/.gemini/config/skills/wingman
# or:
ln -s "$(pwd)/tern-wingman/skills/wingman" ~/.agents/skills/wingman
```

Verify the plugin is `ready`:

```sh
tern plugin list
# wingman 0.1.0 Wingman — 0 blocks, 0 lenses, window  ready
```

</details>

## CLI Reference (`wingman.py`)

`wingman.py` requires only Python 3.10+ standard library (**Linux, macOS & Windows**). Outside Tern (or with `--mode headless`), `send` automatically falls back to detached `omp -p --wait-async --auto-approve`.

```sh
# Inspect live Tern TSP agents, PiP floats, ovnfs availability, and recent sessions
python3 skills/wingman/scripts/wingman.py info --cwd /path/to/project

# Dispatch work to a fresh session ('new'), active pane ('same'), or specific session ID
python3 skills/wingman/scripts/wingman.py send new \
  --cwd /path/to/project \
  --prompt-file /path/to/spec.md

# Dispatch directly into a bottom-right Picture-in-Picture floating pane
python3 skills/wingman/scripts/wingman.py send same --pip br --prompt "Run pytest -q and fix the failing edge case"

# Read structured TSP chat messages & tool cards directly from Tern memory
python3 skills/wingman/scripts/wingman.py transcript --last 6
# Worker blocked on ask/approval (waiting_input): inspect the card, then answer via TSP events
python3 skills/wingman/scripts/wingman.py surface --pane <id> [--json]
python3 skills/wingman/scripts/wingman.py event --pane <id> '{"ev":"action","id":"<id>","act":"pick:0:0"}' '{"ev":"action","id":"<submit_id>","act":"submit"}'

# Float to PiP, dock back into split, interrupt Ctrl-C, cancel queued prompts, or close worker
python3 skills/wingman/scripts/wingman.py pip --corner br
python3 skills/wingman/scripts/wingman.py dock --dir right
python3 skills/wingman/scripts/wingman.py interrupt
python3 skills/wingman/scripts/wingman.py unqueue
python3 skills/wingman/scripts/wingman.py stop

# Bidirectional worker -> supervisor reporting & auto-callback policy
python3 skills/wingman/scripts/wingman.py report -m "Finished v4 pipeline; ready for review"
python3 skills/wingman/scripts/wingman.py callback [status|on|off|reset]
```

### Pairing with `deja-vu` & `ovnfs`

- **Cross-agent memory ([deja-vu](https://github.com/vshulcz/deja-vu))**: `deja` indexes transcripts across 48 coding agents alongside `omp`, giving your lead agent instant historical recall while `tern-wingman` owns live TSP execution.
- **Zero-copy sandboxes ([ovnfs](https://github.com/stencil-hq/ovnfs))**: Run risky refactors or parallel A/B tasks by passing `--cwd "$(ovnfs new .)"`, reviewing with `ovnfs diff`, and landing with `ovnfs apply`.

## Development & Tests

```sh
tern plugin types .                          # optional: generate tern.d.luau for luau-lsp
python3 -m unittest discover -s tests -v     # run unit & loopback bridge tests
```

## License

[MIT](LICENSE) © [ninthcj](https://github.com/ninthcj)
