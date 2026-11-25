# Changelog

All notable changes to `tern-wingman` are documented in this file.

## [0.9.1] - 2026-11-25

### Added
- **On-demand `omp` composer telemetry (`wingman info`)**: Scoped `info` queries expose `context` usage (`j.context`) and active `thinking` level (`j.bar/model/effort`) via O(1) single-node TSP reads (with reverse shallow `dock` fallback) without polluting auto-callbacks or sync `send`/`retry` outputs.
- **Live `--thinking LEVEL` control on `send same`**: `wingman send same --thinking <level>` applies the requested `omp` thinking level via native `thinking.set` right before prompt dispatch—and preserves per-item `thinking` across queued dispatches, edits, and moves—so supervisors can raise effort without `--replace` destroying warm caches.

### Fixed
- **Hot-reload stale-socket race in `call_bridge`**: Stale `.sock` files (`ConnectionRefusedError`) or `_skip` frames during plugin reload no longer prematurely abort active `await` reattachments or reset the socket-discovery budget.

## [0.9.0] - 2026-11-24

### Added
- **`wingman answer` semantic reply CLI/RPC**: Answer blocked `[Wingman waiting_input]` workers directly by 1-based option number (`wingman answer 2`), multi-question picks (`wingman answer 1 3`), free-text `Other…` (`wingman answer --other "..."` with automatic field expansion and UTF-16 `edit` calculation), or approval decisions (`--approve` / `--deny` / `--cancel`) without touching raw TSP node IDs or JSON events.

### Fixed
- **Long-session TSP card & fault resolution**: Scoped region reads (`layer`, `dock`, and reverse tail walk of `main`) find interactive `ask`/approval cards and `F5 to retry` faults in O(1) regardless of transcript length, and empty `layer` containers no longer mask active cards.
- **`wingman event` target validation**: Validates target node existence on the live TSP surface before sending, stopping at the first missing node ID and reporting the active interactive root instead of silently succeeding as a no-op.
- **Eliminated delayed / duplicate escalations**: `event` and `answer` keep `notified_waiting` deduplication intact until Tern transitions out of `waiting_input`, and queued `waiting_input` / `fault` callbacks are automatically purged or live-verified before delivery while preserving turn-completion callbacks.
- **Unbounded `--wait` across plugin reloads**: `call_bridge` keeps socket-discovery timeouts separate from the caller's turn deadline so hot-reloads never cap an unbounded wait to 5 seconds.

### Changed
- **Pure-signal agent outputs & perspective isolation**:
  - `[Wingman waiting_input]` callbacks present clean questions and numbered choices without internal TSP widget trees or coaching boilerplate, and completion callbacks collapse TUI `<svg>` markup so prose conclusions are never truncated.
  - `wingman info` inside Tern defaults to the caller's control domain (bound workers, direct owner, and adoptable same-tab peers, excluding `isSelf`, other tabs, and disk session scans unless `--all` / `--sessions` is passed).
  - `wingman surface` without `--all` or `--root` reports only the active interactive card, retry fault, or a 1-line pane state—never historical chat scrollback.
  - `wingman transcript` defaults to 6 messages, an 8,000-char water-filling cap, and 1-line tool summaries without raw `tools[].text` or TSP UI widget props (opt in with `--tools` or `--full`).

## [0.8.1] - 2026-11-23

### Fixed
- **CLI PiP free-corner auto-selection**: Omitting `--pip <corner>` on `wingman send --layout pip` and omitting `--corner` on `wingman pip` now preserve `nil` through to `window.luau` so multiple PiP floats automatically pick unoccupied corners (`br → tr → bl → tl`) instead of stacking on `br`.

## [0.8.0] - 2026-11-23

### Removed
- **Removed out-of-band `wingman report` CLI/RPC (`op == "report"`, `reported_in_turn`)**: Workers no longer inject mid-turn `progress`/`question` messages into a supervisor's composer while continuing to run (`working`), eliminating state/message desynchronization and queued-reply deadlocks. All upward communication now aligns strictly with Tern's native agent states (`agent_finished` auto-callback on turn end and `waiting_input` surface escalation).

### Changed
- `info` fast path: live-state only, reports `availableAgents`; `--no-sessions` / `--limit 0` skip session scanning.
- `send` and `retry` accept `--json`; `transcript --max-chars N` bounds output; stale pane ids are recovered by re-running `info`.

### Added
- **Native queue search, Files button & status segments:** two-step **Search / Manage Queue** picker across the window, **Send selection to Agent** in the Files pane header (prefills path context), and Wingman-only `fault` / `Q<n>` / `↩<n>` indicators in Tern's Plugin segments widget (no overlap with Tern's native Agents widget or Git block).
- **Standalone Workbench:** Wingman Live now gives any Tern agent, bound or unbound, PiP, Park, and an editable task queue. **Wingman: Queue Prompt for Agent** sends or queues a prompt using Tern’s native picker/input. Queue rows support Top, Edit, and Cancel by stable ID; shell queue commands can select the tab’s sole unowned live agent.
- **Live Panel open by default:** Wingman Live opens automatically (unfocused) whenever a live agent is present, and remembers your open/closed preference in `radar_v1` once you close or reopen it.

## [0.7.0] - 2026-11-23

### Added
- Editable pending-task queues with stable IDs: `wingman queue list`, `edit`, `cancel`, `move`, and `reorder`; `send --position`, `unqueue --id`, and per-agent `queuedItems` in `info`.
- Opt-in **Subagent Panes**: non-focus-stealing canvas strips with a default limit of 3, unlimited wrapping, pinning, and overflow cycling. Radar’s sampler is shared; completed panes expire after a 20-second grace period unless pinned.

### Fixed
- Rapid sends queue in Wingman while the first prompt is entering the native agent, so subsequent tasks remain editable.
- The Live Panel’s viewport calculation reads the current transcript tool records.

## [0.6.0] - 2026-11-22

### Added
- **Universal Agent-to-Agent delegation (`--agent ID`)**: Launch any Tern ACP agent (`claude`, `codex`, `copilot`, or custom `agents.custom` entries such as `agy`) via `tern acp <id>` alongside the default `omp` wingman, with native `--model`, `--continue` (`latest`), and `--resume <session-id>` passthrough.
- **Multi-level ownership tree & cycle guard**: Wingmen can supervise wingmen of their own; explicit bindings that would form a cycle (self or ancestor) are rejected before any side effects.
- **Dynamic PiP sizing & free-corner selection**: Floating workers scale proportionally to the owner's tab share and sibling float count, and automatically pick the first unoccupied corner (`br → tr → bl → tl`) when no corner is specified.
- **Dynamic Live Panel scaling**:
  - Manually resizing the Live Panel sidebar persists `sidebar_share` in `radar_v1`; floating size scales proportionally to the tab's layout across resolutions and operating systems.
  - Activity loom strips, transcript feed count, and Living Files read-only file budgets adapt dynamically to the panel's rendered width/height share and active agent/git load.
  - Cross-OS path normalization for macOS, Linux, and Windows repositories and home paths.
- **Callback & escalation polish**:
  - Explicit UTF-8-safe truncation notice when callback summaries exceed 3,600 bytes, pointing supervisors to `wingman transcript --pane <id> --last 2`.
  - Native ACP `layer` overlay extraction in `waiting_input` summaries so approval/ask dialogs render cleanly without raw JSON metadata dumps.
  - Unified `-m -` piped stdin support in `wingman report` and one-word `wingman <subcmd>` runtime hints.

### Changed
- **Modular 5-file acyclic Luau architecture**: Split the window plugin into `window.luau` (control plane & layouts), `state.luau` (`owners_v1` graph, `bindings_v1` migration, cycle guard, callback state), `tsp.luau` (stateless TSP/surface helpers & UTF-8 clipping), `radar.luau` (Live Panel controller & 50 ms budget guard), and `radar_view.luau` (pure declarative CSS & UI renderer).
- **Smart multi-worker layout**: Additional `split` / `dock` workers stack cleanly in the right column (`tiled_slot`), and `unpark` returns a worker beside its owner without splitting a focused Live Panel.

## [0.5.0] - 2026-11-22

### Added
- **1-to-N wingmen (`owners_v1`)**: One supervisor can own multiple concurrent wingmen; `send new` adds a worker, `send new --replace` explicitly replaces a selected bound worker, and `--pane` / unique `--cwd` disambiguate targets.
- **Native layouts (`--layout split|down|pip|tab|park`) & `park` / `unpark`**: Non-intrusive placement without stealing keyboard focus.
- **Wingman Live Panel (`radar.luau`)**: Native Tern canvas sidebar/PiP + widget bar counter showing topology, Living Files (`git status` ∪ agent edits/reads), live activity loom & transcript feed, and one-click Focus / PiP / Dock / Interrupt / Retry / Unqueue under a strict 50 ms Lua hook budget.
- **Cleaner escalations**: Stripped noisy raw JSON tool-call metadata from `waiting_input` escalations.

## [0.4.2] - 2026-11-19

### Added
- **Takeover-only stalled fault escalation & native `/retry`**: Automatically escalates failed/aborted worker turns to supervisors as `[Wingman fault · retryable · pane <id>]` and exposes `wingman retry --pane <id>` (native `/retry`, equivalent to `F5`).

## [0.4.1] - 2026-11-19

### Documentation
- Documented native TSP event patterns for `Other` free-text input and option notes when answering `waiting_input` cards.

## [0.4.0] - 2026-11-19

### Added
- **Native TSP `waiting_input` escalation & surface/event delivery**: Automatically surfaces interactive `ask` / approval cards to supervisors and adds `wingman surface` and `wingman event` for answering them over TSP.

## [0.3.0] - 2026-11-19

### Changed
- **Non-blocking async default for Tern ACP callers**: Tern agents calling `send` / `retry` default to `--async` with automatic completion callback via `cx.agents:ask`, keeping the supervisor's live UI responsive; plain shells retain `--wait`.

## [0.2.1] - 2026-11-18

### Added
- **Native Windows compatibility**: Full cross-platform support for Linux, macOS, and Windows in `wingman.py` and `mux.py`.

## [0.2.0] - 2026-11-18

### Added
- **Full-duplex callbacks (`report` + `auto_callback_v1`)**: Workers can proactively push progress or questions to their `boundOwner` via `wingman report`, and unsolicited follow-up turns (e.g., internal background jobs) automatically wake the supervisor with coalescing when busy.
- **Native per-pane FIFO dispatch queue & `unqueue`**: Prompts sent to a busy worker queue in `window.luau` and advance automatically on `agent_finished`.

## [0.1.1] - 2026-11-17

### Changed
- Replaced timer/HTTP polling with a zero-polling `0600` `AF_UNIX` event bus (`mux.py` via `tern.process.spawn`) and explicit pane ownership persisted across `tern plugin reload`.

## [0.1.0] - 2026-11-17

### Added
- Initial release of `tern-wingman`: native Tern `WindowCx.agents` TSP bridge (`window.luau`), zero-dependency Python 3.10+ CLI (`wingman.py`), Picture-in-Picture floating/docking, and portable agent skill (`skills/wingman/SKILL.md`).
