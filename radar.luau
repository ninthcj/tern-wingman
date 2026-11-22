--!strict
-- Wingman Live Panel ("radar"): a canvas over wingman's control plane — owner ↔ wingman topology, the files agents
-- touch (git ∪ tool calls) and their recent tool calls. window.luau hands it a narrow Bridge (read-only accessors plus
-- the same pip/dock/interrupt/retry/unqueue cores its RPC uses) and calls `on_state_change` when that state moves.
--
-- Budget (tern.d.luau): every window-half call may run 50 ms of Lua (native calls — `cx.*`, `tern.ui`, `tern.json` —
-- excluded) and ten budgets of wall time; past either, Tern pauses that hook for 5 s, doubling to 5 min, and every
-- timer callback shares one hook with wingman's watchdog. So the radar bounds itself:
--   * Panel closed: event handlers keep O(1) per-agent state for the widget. No timer, no transcript, no git.
--   * Panel open: event-driven renders coalesce into one timer; a tick runs only while an in-scope agent works, spaced
--     so the radar's average share of the window thread stays under MAX_DUTY.
--   * Each render times its Lua and native parts. Past SAFE_MS of Lua (or SAFE_WALL_MS of wall time) the next renders
--     skip transcript sampling ("lite": agents + git) for a cooldown that doubles like Tern's own pause; a `budget`
--     event trips it too. A lite render still over shrinks the node budget in proportion.
-- Tool calls come from `cx.agents:transcript`, which carries the same TSP tool cards for omp and ACP panes
-- (~0.1–0.6 ms a pane). `cx.session:surface` is never read here: one omp surface costs ~20 ms.

-- The panel's placement: the right sidebar takes TAB_SHARE of its tab's width; a float takes FLOAT_SIZE (a value
-- above 1 is terminal cells, up to 1 a share of the pane it floats over).
local TAB_SHARE = 0.24
local RATIO_MIN, RATIO_MAX = 0.22, 0.45
local FLOAT_SIZE = { 46, 0.85 }

export type Bridge = {
	--- A copy of the wingman (worker) → owner map; an owner may have several wingmen.
	owners: () -> { [number]: number },
	--- Prompts queued for a busy pane.
	queued_dispatches: (pane: number) -> number,
	--- Callbacks waiting for a busy owner pane.
	queued_callbacks: (pane: number) -> number,
	--- The `waiting_input`/fault escalation key last pushed to the pane's owner.
	notified_waiting: (pane: number) -> string?,
	--- The fault summary the control plane escalated for the pane, if any.
	fault: (pane: number) -> string?,
	pip: (cx: WindowCx, pane: number) -> (boolean, string?),
	dock: (cx: WindowCx, pane: number) -> (boolean, string?),
	park: (cx: WindowCx, pane: number) -> (boolean, string?),
	unpark: (cx: WindowCx, pane: number) -> (boolean, string?),
	interrupt: (cx: WindowCx, pane: number) -> (boolean, string?),
	retry: (cx: WindowCx, pane: number) -> (boolean, string?),
	--- Cancels every queued prompt of the pane; returns how many.
	unqueue: (cx: WindowCx, pane: number) -> number,
}

type Scope = "tab" | "all"
type Placement = "right" | "float"

type Row = {
	pane: number,
	state: string,
	title: string,
	model: string?,
	cwd: string,
	tab: number?,
	floating: boolean,
	focused: boolean,
	owner: number?,
	workers: { number },
	parked: boolean,
	place: string?, -- "pip" | "tab" | "parked" relative to the owner, else nil
	queued: number,
	inbox: number,
	fault: string?,
	failed: boolean,
}

type ToolRec = {
	id: string,
	pane: number,
	name: string,
	target: string,
	kind: string, -- "edit" | "read" | "run" | "other"
	path: string?,
	status: string,
	took: number?, -- ms, when done
	exact: boolean, -- false when first seen in a cold sample: it started before `seen`
	seen: number,
	seq: number,
}

type GitEntry = { path: string, code: string, ins: number, del: number, conflict: boolean }

type Repo = {
	root: string,
	branch: string?,
	files: { GitEntry }?,
	err: string?,
	inflight: boolean,
	dirty: boolean,
	next_at: number,
}

type FileRow = {
	abs: string,
	code: string?,
	ins: number,
	del: number,
	conflict: boolean,
	edits: number,
	reads: number,
	last: number,
	panes: { [number]: boolean },
}

type Budget = { left: number }

local TITLE = "Wingman Live"
local ROLE = "wingman.radar"
local WIDGET = "radar"
local KV_RADAR = "radar_v1"
local TOGGLE_ACTION = "plugin." .. tern.plugin.id .. ".toggle_panel"
local ABOUT = "Live view of this window's coding agents (omp and ACP) and their wingman bindings, the files they touch "
	.. "(git status merged with the paths of their recent read/search/edit tool calls) and their recent tool calls. "
	.. "Clicking an agent focuses its pane; a placement chip (pip, tab, parked) shows where a wingman sits relative to "
	.. "its owner; PiP floats a wingman over its owner and Dock puts it back; Park hides a wingman (it keeps running) "
	.. "and Unpark brings it into the current tab; Interrupt sends "
	.. "Ctrl-C to that agent's turn; Retry sends /retry to a stalled agent; Unqueue cancels prompts queued for it. "
	.. "Clicking a file opens it beside; Open Git opens the git block; Clear Reads hides read/search touches; Tab/All "
	.. "picks which agents show. Nothing runs on its own."

local BUDGET_MS = 50 -- window-half Lua budget per call (tern.d.luau)
local SAFE_MS = BUDGET_MS * 0.2 -- the radar's share of any one call's Lua time
local SAFE_WALL_MS = 10 * BUDGET_MS * 0.2 -- the same share of a call's wall-time cap (ten budgets)
local PAUSE_MIN_MS = 5000 -- Tern's own hook pause: 5 s, doubling to 5 min
local PAUSE_MAX_MS = 300000
local TICK_MIN_MS = 1000 -- elapsed and duration labels resolve to seconds
local MAX_DUTY = 0.02 -- average share of the window thread the tick may take
local GIT_MAX_DUTY = 0.1 -- share of the git engine's time a repo's periodic status may take
local NODE_CAP = 2000 * 0.5 -- half of the canvas caps
local NODE_FLOOR = 200 -- what a shrunk budget keeps: the topology and a few files
local BYTE_CAP = 256 * 1024 * 0.5
local TOOL_ROWS = 30 -- rows the tool stream shows: about a screenful of a sidebar
local FILE_ROWS = 40 -- rows living files show (git changes past it fold into "… N more")
local COLD_MSGS = TOOL_ROWS -- a pane's first sample: at least a stream's worth of calls (omp ~1 per message, ACP more)
local WARM_MSGS = 10 -- later samples: more tool calls than one tick can add
local MAX_MSGS = 100 -- widest sample: a call still running after ~100 newer messages is dropped as lost
local TOOL_KEEP = 80 -- tool records kept per pane for file touches: a few screens of its stream

local HOME = tern.getenv("HOME") or tern.getenv("USERPROFILE")

-- The panel's sheet: a stage lit by the agents' mood, cards on a rail, a compact file tree, a feed. Colors come
-- from Tern's tokens through relative colors (Tern drops a gradient stop whose `var()` holds `light-dark()`);
-- motion is CSS only, so it costs no Lua and Reduce Motion stops it. Reinstalled on every load: Tern drops
-- plugin sheets on reload but keeps the canvas.
local CSS = [==[
.wr { display: flex; flex-direction: column; gap: 14px; min-width: 0; font: 400 12px/16px var(--sans); color: var(--t1); }
.wr-eyebrow { font: 600 9.5px/12px var(--mono); letter-spacing: 0.14em; text-transform: uppercase; color: var(--t3); white-space: nowrap; }
.wr-meta { margin-left: auto; font: 500 10.5px/14px var(--mono); font-variant-numeric: tabular-nums; color: var(--t3); white-space: nowrap; }
.wr-time { flex: none; font: 500 10.5px/14px var(--mono); font-variant-numeric: tabular-nums; color: var(--t3); white-space: nowrap; }
.wr-empty, .wr-more { padding: 2px 4px; font: 400 11.5px/16px var(--sans); color: var(--t3); }
.wr-warn { padding: 2px 4px; font: 500 11px/16px var(--sans); color: var(--warn); }
.wr-sec { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.wr-sh { display: flex; align-items: center; gap: 8px; padding: 0 2px; }

/* stage */
.wr-stage { position: relative; display: flex; flex-direction: column; gap: 10px; padding: 11px 12px 12px; border-radius: 12px;
	overflow: hidden; background-color: var(--code-bg); box-shadow: 0 0 0 1px var(--l2), inset 0 1px 0 var(--glass-hi);
	--wr-mood: var(--t4); }
.wr-stage[data-mood='working'] { --wr-mood: var(--accent); }
.wr-stage[data-mood='waiting'] { --wr-mood: var(--warn); }
.wr-stage[data-mood='fault'] { --wr-mood: var(--bad); }
.wr-stage::before { content: ""; position: absolute; inset: 0; pointer-events: none;
	background-image: radial-gradient(130% 150% at 0% 0%, rgb(from var(--wr-mood) r g b / 20%), rgb(from var(--wr-mood) r g b / 0%) 62%); }
.wr-stage[data-mood='idle']::before { opacity: 0.5; }
.wr-stage[data-mood='working']::before { animation: wr-breathe 3.6s ease-in-out infinite; }
@keyframes wr-breathe { 0%, 100% { opacity: 0.55; } 50% { opacity: 1; } }
.wr-top { position: relative; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; min-width: 0; }
.wr-seg { margin-left: auto; display: flex; flex: none; padding: 2px; border-radius: 7px; background-color: var(--l1); }
.wr-seg .wr-sb.sf-el { padding: 0 9px; min-height: 0; border: 0; border-radius: 5px; background-color: transparent; box-shadow: none;
	font: 500 11px/18px var(--sans); color: var(--t3); cursor: pointer; }
.wr-seg .wr-sb.sf-el:hover { color: var(--t1); }
.wr-seg .wr-sb.sf-el[data-on] { background-color: var(--card); color: var(--t1); box-shadow: 0 1px 2px rgb(0 0 0 / 18%), 0 0 0 1px var(--l2); }
.wr-tiles { position: relative; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 5px; }
.wr-tile { display: flex; flex-direction: column; gap: 1px; min-width: 0; padding: 5px 7px 6px; border-radius: 8px;
	background-color: var(--well); box-shadow: 0 0 0 1px var(--well-line); }
.wr-n { font: 600 17px/20px var(--mono); font-variant-numeric: tabular-nums; color: var(--t1); }
.wr-tl { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 500 8.5px/11px var(--mono); letter-spacing: 0.1em;
	text-transform: uppercase; color: var(--t3); }
.wr-tile[data-k='working'] .wr-n { color: var(--accent); }
.wr-tile[data-k='waiting'] .wr-n, .wr-tile[data-k='queued'] .wr-n { color: var(--warn); }
.wr-tile[data-k='fault'] .wr-n { color: var(--bad); }
.wr-tile[data-zero] .wr-n { color: var(--t4); }

/* icon buttons: Tern's button chrome off, quiet until the card is hovered */
.wr-ib.sf-el { display: flex; flex: none; align-items: center; justify-content: center; width: 22px; height: 20px; min-height: 0;
	padding: 0; border: 0; border-radius: 5px; background-color: transparent; box-shadow: none; color: var(--t2); cursor: pointer; }
.wr-ib.sf-el:hover { background-color: var(--l2); color: var(--t1); }

/* agents */
.wr-cards { display: flex; flex-direction: column; gap: 8px; }
.wr-card { display: flex; flex-direction: column; gap: 6px; min-width: 0; padding: 8px 9px 9px; border-radius: 10px;
	background-color: var(--well); box-shadow: 0 0 0 1px var(--well-line); }
.wr-wm { display: flex; flex-direction: column; gap: 5px; min-width: 0; position: relative; }
.wr-wm::before { content: ""; position: absolute; left: -13px; top: 8px; width: 9px; height: 1px; background-color: var(--l3); }
.wr-kids { position: relative; display: flex; flex-direction: column; gap: 8px; margin: 2px 0 0 3px; padding-left: 13px; min-width: 0; }
.wr-kids::before { content: ""; position: absolute; left: 0; top: -4px; bottom: 7px; width: 1px; background-color: var(--l3); }
.wr-row { display: flex; align-items: center; gap: 4px; min-width: 0; }
.wr-hit { display: flex; flex: 1; align-items: center; gap: 7px; min-width: 0; cursor: pointer; }
.wr-name { flex: 0 1 auto; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 600 12.5px/16px var(--sans); }
.wr-name[data-focused] { color: var(--accent); }
.wr-hit .wr-time { margin-left: auto; }
.wr-acts { display: flex; flex: none; gap: 1px; opacity: 0.4; }
.wr-card:hover .wr-acts { opacity: 1; }
.wr-dot { flex: none; width: 8px; height: 8px; border-radius: 4px; background-color: var(--t4); }
.wr-dot[data-s='working'] { background-color: var(--accent); animation: wr-pulse 1.6s ease-out infinite; }
.wr-dot[data-s='waiting'] { background-color: var(--warn); box-shadow: 0 0 0 3px rgb(from var(--warn) r g b / 22%); }
.wr-dot[data-s='fault'] { background-color: var(--bad); box-shadow: 0 0 0 3px rgb(from var(--bad) r g b / 22%); }
.wr-dot[data-s='exited'] { background-color: transparent; box-shadow: inset 0 0 0 1.5px var(--t4); }
@keyframes wr-pulse { 0% { box-shadow: 0 0 0 0 rgb(from var(--accent) r g b / 55%); } 100% { box-shadow: 0 0 0 6px rgb(from var(--accent) r g b / 0%); } }
.wr-hue { flex: none; width: 6px; height: 6px; border-radius: 3px; background-color: var(--t3); }
.wr-hue[data-hue='0'] { background-color: oklch(70% 0.13 255); }
.wr-hue[data-hue='1'] { background-color: oklch(72% 0.14 155); }
.wr-hue[data-hue='2'] { background-color: oklch(76% 0.14 75); }
.wr-hue[data-hue='3'] { background-color: oklch(68% 0.15 330); }
.wr-hue[data-hue='4'] { background-color: oklch(72% 0.12 200); }
.wr-hue[data-hue='5'] { background-color: oklch(68% 0.15 25); }
.wr-chip { flex: none; padding: 0 5px; border-radius: 4px; font: 600 10px/15px var(--mono); color: var(--t2); background-color: var(--l1); }
.wr-chip[data-t='warn'] { color: var(--warn); background-color: rgb(from var(--warn) r g b / 14%); }
.wr-chip[data-t='bad'] { color: var(--bad); background-color: rgb(from var(--bad) r g b / 14%); }
.wr-tool { display: flex; align-items: center; gap: 6px; min-width: 0; padding-left: 15px; font: 500 11px/16px var(--mono); cursor: pointer; }
.wr-k { flex: none; max-width: 92px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; padding: 0 5px; border-radius: 4px;
	font: 600 10px/15px var(--mono); color: var(--t2); background-color: var(--l1); }
.wr-k[data-k='edit'] { color: var(--accent); background-color: rgb(from var(--accent) r g b / 13%); }
.wr-k[data-k='run'] { color: var(--warn); background-color: rgb(from var(--warn) r g b / 13%); }
.wr-k[data-k='read'] { color: var(--rail); background-color: rgb(from var(--rail) r g b / 12%); }
.wr-k[data-k='error'] { color: var(--bad); background-color: rgb(from var(--bad) r g b / 13%); }
.wr-tgt { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; color: var(--t2); }
.wr-loom { display: flex; gap: 2px; height: 9px; padding-left: 15px; overflow: hidden; }
.wr-b { flex: 0 0 6px; border-radius: 2px; background-color: var(--l3); }
.wr-b[data-k='read'] { background-color: rgb(from var(--rail) r g b / 55%); }
.wr-b[data-k='search'] { background-color: rgb(from var(--t2) r g b / 35%); }
.wr-b[data-k='edit'] { background-color: var(--accent); }
.wr-b[data-k='run'] { background-color: var(--warn); }
.wr-b[data-k='error'] { background-color: var(--bad); }
.wr-b[data-run] { animation: wr-live 1.1s ease-in-out infinite; }
@keyframes wr-live { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }

/* living files */
.wr-repo { display: flex; align-items: center; gap: 7px; min-width: 0; padding: 1px 4px; color: var(--t3); }
.wr-br { flex: none; max-width: 40%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; padding: 0 6px; border-radius: 4px;
	font: 500 10.5px/16px var(--mono); color: var(--t2); background-color: var(--l1); }
.wr-repo-n { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 500 12px/16px var(--sans); color: var(--t1); }
.wr-dir { padding: 3px 4px 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 500 10.5px/18px var(--mono); color: var(--t3); }
.wr-files { position: relative; display: flex; flex-direction: column; margin-left: 6px; padding-left: 8px; }
.wr-files::before { content: ""; position: absolute; left: 0; top: 2px; bottom: 6px; width: 1px; background-color: var(--l2); }
.wr-file { display: flex; align-items: center; gap: 6px; min-width: 0; min-height: 22px; padding: 0 4px; border-radius: 5px; cursor: pointer; }
.wr-file:hover { background-color: var(--l1); }
.wr-st { flex: none; width: 10px; text-align: center; font: 700 10px/14px var(--mono); color: var(--t4); }
.wr-st[data-s='M'], .wr-st[data-s='R'], .wr-st[data-s='T'] { color: var(--warn); }
.wr-st[data-s='A'], .wr-st[data-s='?'], .wr-st[data-s='C'] { color: var(--ok); }
.wr-st[data-s='D'], .wr-st[data-s='U'] { color: var(--bad); }
.wr-fn { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 500 12px/16px var(--sans); }
.wr-file[data-read] .wr-fn { color: var(--t3); }
.wr-hot { flex: none; width: 6px; height: 6px; border-radius: 3px; background-color: var(--accent);
	box-shadow: 0 0 6px 1px rgb(from var(--accent) r g b / 60%); }
.wr-who { flex: none; display: flex; gap: 2px; }
.wr-bar { flex: none; display: flex; width: 30px; height: 4px; border-radius: 2px; overflow: hidden; background-color: var(--l1); }
.wr-a { background-color: var(--ok); }
.wr-d { background-color: var(--bad); }
.wr-bar [data-w='1'] { width: 2px; } .wr-bar [data-w='2'] { width: 5px; } .wr-bar [data-w='3'] { width: 9px; }
.wr-bar [data-w='4'] { width: 13px; } .wr-bar [data-w='5'] { width: 18px; } .wr-bar [data-w='6'] { width: 24px; }
.wr-ln { flex: none; white-space: nowrap; text-align: right; font: 500 10px/14px var(--mono); font-variant-numeric: tabular-nums; }
.wr-file .wr-ln { min-width: 52px; }
.wr-add { color: var(--ok); }
.wr-del { color: var(--bad); }

/* activity */
.wr-act { display: flex; align-items: center; gap: 7px; min-width: 0; min-height: 21px; padding: 0 4px; border-radius: 5px;
	font: 500 11px/16px var(--mono); cursor: pointer; }
.wr-act:hover { background-color: var(--l1); }
.wr-act[data-run] .wr-time { color: var(--accent); }
.wr-act[data-lost] { opacity: 0.55; }

/* dock */
.wr-dock { display: flex; align-items: center; gap: 6px; min-width: 0; }
.wr-dock .wr-btn.sf-el { display: flex; align-items: center; gap: 5px; min-height: 0; padding: 3px 9px; border: 0; border-radius: 6px;
	background-color: transparent; box-shadow: 0 0 0 1px var(--l2); font: 500 11.5px/16px var(--sans); color: var(--t2); cursor: pointer; }
.wr-dock .wr-btn.sf-el:hover { background-color: var(--l1); color: var(--t1); }
.wr-lite { margin-left: auto; padding: 0 6px; border-radius: 4px; font: 600 10px/15px var(--mono); color: var(--warn);
	background-color: rgb(from var(--warn) r g b / 14%); }
.wr-health { margin-left: auto; flex: none; width: 7px; height: 7px; border-radius: 4px; background-color: var(--ok); opacity: 0.6; }
.wr-lite + .wr-health { margin-left: 0; }
.wr-health[data-mode='lite'] { background-color: var(--warn); opacity: 1; }

@media (prefers-reduced-motion: reduce) {
	.wr-stage::before, .wr-dot, .wr-b { animation: none !important; }
}
]==]

local KIND: { [string]: string } = {
	edit = "edit",
	write = "edit",
	ast_edit = "edit",
	notebook = "edit",
	apply_patch = "edit",
	multi_edit = "edit",
	read = "read",
	grep = "read",
	find = "read",
	glob = "read",
	ast_grep = "read",
	search = "read",
	lsp = "read",
	bash = "run",
	eval = "run",
	ssh = "run",
	tool = "run", -- ACP agents report shell runs as a generic `tool`
	-- ACP agents (Antigravity, Claude Code): the card's title names the tool.
	view_file = "read",
	list_dir = "read",
	grep_search = "read",
	find_by_name = "read",
	codebase_search = "read",
	read_url_content = "read",
	write_to_file = "edit",
	replace_file_content = "edit",
	multi_replace_file_content = "edit",
	run_command = "run",
	command_status = "run",
}

local CHANGE: { [string]: string } = {
	modified = "M",
	added = "A",
	deleted = "D",
	renamed = "R",
	copied = "C",
	untracked = "?",
	typechange = "T",
	unmerged = "U",
}

-- Widget state, kept while the panel is closed: O(1) per agent per event.
local bridge: Bridge? = nil
local states: { [number]: string } = {}
local titles: { [number]: string } = {}
local since: { [number]: number } = {} -- tern.now() when the agent entered its state
local since_wall: { [number]: number } = {} -- os.time() of the same moment
local exact: { [number]: boolean } = {} -- false when first seen mid-state (after a reload)
local placement_last = "" -- `placement_sig` of the latest render
local layout_armed = false
local schedule_layout_render: () -> ()
local finished: { [number]: string } = {} -- last agent_finished result
local change_sig = ""
local widget_sig = ""

-- Panel state.
local panel_pane: number? = nil
local scope: Scope = "tab"
local placement: Placement = "right"
local corner: Corner = "br"
local hue_of: { [number]: number } = {} -- identity color per agent, in first-seen order (the seed sorts by pane)
local next_hue = 0
local render_armed = false
local tick_handle: TimerHandle? = nil
local catchup_handle: TimerHandle? = nil
local any_working = false
local primary_root: string? = nil
local cwd_of: { [number]: string } = {}

-- Tool records, newest last in `tool_ids`; dropped when the panel closes.
local tools: { [string]: ToolRec } = {}
local tool_ids: { string } = {}
local tool_seq = 0
local window_ids: { [number]: { [string]: boolean } } = {} -- ids of each pane's last sample
local sample_last: { [number]: number } = {} -- messages the pane's next sample reads
local tool_dirty: { [number]: boolean } = {}
local cleared: { [string]: boolean } = {}

-- Git: one in-flight call per cwd and per root, kept across close/reopen so calls never pile up.
local roots_by_cwd: { [string]: string | false } = {}
local cwd_inflight: { [string]: boolean } = {}
local repos: { [string]: Repo } = {}

-- Adaptive guard.
local mode = "rich"
local lite_until = 0
local lite_reason = ""
local pause_ms = 0
local node_cap = NODE_CAP
-- The last render's cost. Tern charges a call's Lua time to the 50 ms budget, not its native calls (`cx.*`,
-- `tern.json`), and caps the whole call at ten budgets of wall time; `native_ms` accumulates the native part.
local last_wall = 0
local last_lua = 0
local last_nodes = 0
local last_bytes = 0
local last_phases = ""
local native_ms = 0
local renders = 0 -- renders since load, shown in the dock's tooltip
local logged: { [string]: boolean } = {}

-- `pcall` for a function that returns nothing (Luau types that `pcall` as returning only the boolean).
local function try(fn: () -> ()): (boolean, string?)
	return pcall(function(): string?
		fn()
		return nil
	end)
end

local function log_once(what: string, err: any)
	local msg = what .. ": " .. tostring(err)
	if not logged[msg] then
		logged[msg] = true
		tern.log.warn("wingman radar " .. msg)
	end
end

local function clip(s: string, n: number): string
	local len = utf8.len(s)
	if len == nil then
		return if #s > n then string.sub(s, 1, n) .. "…" else s
	end
	if len <= n then
		return s
	end
	local cut = utf8.offset(s, n) or (n + 1)
	return string.sub(s, 1, cut - 1) .. "…"
end

-- Keeps the end of `s`, where a path's file name is.
local function clip_start(s: string, n: number): string
	local len = utf8.len(s)
	if len == nil or len <= n then
		return s
	end
	local cut = utf8.offset(s, len - n + 2) or 1
	return "…" .. string.sub(s, cut)
end

local function one_line(s: string): string
	return (string.gsub(s, "%s+", " "))
end

local function spans_text(v: any): string
	if type(v) == "string" then
		return v
	elseif type(v) == "table" then
		if type(v.t) == "string" then
			return v.t
		end
		local buf: { string } = {}
		for _, item in ipairs(v) do
			if type(item) == "string" then
				table.insert(buf, item)
			elseif type(item) == "table" and type(item.t) == "string" then
				table.insert(buf, item.t)
			end
		end
		return table.concat(buf, "")
	end
	return ""
end

local function fmt_dur(ms: number): string
	if ms < 1000 then
		return string.format("%dms", math.floor(ms))
	end
	local s = ms / 1000
	if s < 60 then
		return string.format("%.1fs", s)
	elseif s < 3600 then
		return string.format("%dm%02ds", s // 60, math.floor(s % 60))
	end
	return string.format("%dh%02dm", s // 3600, math.floor((s % 3600) / 60))
end

local function short_pane(pane: number): string
	return string.format("#%04d", pane % 10000)
end

local function basename(path: string): string
	return string.match(path, "([^/\\]+)[/\\]*$") or path
end

local function display_path(abs: string, roots: { string }): string
	for _, root in roots do
		if string.sub(abs, 1, #root + 1) == root .. "/" then
			local rel = string.sub(abs, #root + 2)
			return if #roots > 1 then basename(root) .. "/" .. rel else rel
		end
	end
	if HOME and string.sub(abs, 1, #HOME + 1) == HOME .. "/" then
		return "~" .. string.sub(abs, #HOME + 1)
	end
	return abs
end

local function count_nodes(n: Node): number
	local c = 1
	local kids = n.c
	if kids then
		for _, k in kids do
			c += count_nodes(k)
		end
	end
	return c
end

local function fits(b: Budget, n: Node): boolean
	local c = count_nodes(n)
	if c > b.left then
		return false
	end
	b.left -= c
	return true
end

local function track(pane: number, state: string, title: string?, seen_change: boolean)
	if states[pane] ~= state then
		states[pane] = state
		since[pane] = tern.now()
		since_wall[pane] = os.time()
		exact[pane] = seen_change
	elseif seen_change and not exact[pane] then
		exact[pane] = true -- a render saw the new state just before its event arrived
	end
	if title and title ~= "" then
		titles[pane] = title
	end
end

-- Drops the pane's oldest tool records until `keep` remain; per pane, so a busy agent can't push out an idle one's.
local function drop_tools(pane: number, keep: number)
	local count = 0
	for _, id in tool_ids do
		if tools[id].pane == pane then
			count += 1
		end
	end
	local extra = count - keep
	if extra <= 0 then
		return
	end
	local kept: { string } = {}
	for _, id in tool_ids do
		if extra > 0 and tools[id].pane == pane then
			extra -= 1
			tools[id], cleared[id] = nil, nil
		else
			table.insert(kept, id)
		end
	end
	tool_ids = kept
end

local function forget_agent(pane: number)
	states[pane], titles[pane], since[pane], since_wall[pane] = nil, nil, nil, nil
	exact[pane], finished[pane], cwd_of[pane], hue_of[pane] = nil, nil, nil, nil
	window_ids[pane], sample_last[pane], tool_dirty[pane] = nil, nil, nil
	drop_tools(pane, 0)
end

------------------------------------------------------------------------------------------------------------------------
-- Widget

local function sorted_panes(): { number }
	local panes: { number } = {}
	for pane in states do
		table.insert(panes, pane)
	end
	table.sort(panes)
	return panes
end

local function widget_view(_pane: StatusPaneInfo?): WidgetView?
	local b = bridge
	if b == nil then
		return nil
	end
	local working, waiting, queued = 0, 0, 0
	local card: { WidgetCardRow } = {}
	for _, pane in sorted_panes() do
		local state = states[pane]
		local fault = b.fault(pane)
		if state == "working" then
			working += 1
		elseif state == "waiting_input" or fault ~= nil then
			waiting += 1
		end
		local q = b.queued_dispatches(pane)
		queued += q
		if #card < 32 then
			local label = if fault ~= nil then "fault" elseif state == "waiting_input" then "waiting" else state
			table.insert(card, {
				id = tostring(pane),
				label = clip(label .. (if q > 0 then " · Q:" .. q else ""), 40),
				text = clip(titles[pane] or short_pane(pane), 120),
				tone = if fault ~= nil then "error" elseif state == "waiting_input" then "warn" else nil,
				actions = { { id = "focus", label = "Focus" } },
			})
		end
	end
	local parts: { string } = {}
	if working > 0 then
		table.insert(parts, working .. " working")
	end
	if waiting > 0 then
		table.insert(parts, waiting .. " waiting")
	end
	if queued > 0 then
		table.insert(parts, queued .. " queued")
	end
	return {
		text = if #parts > 0 then table.concat(parts, " · ") else "idle",
		tone = if waiting > 0 then "warning" elseif working > 0 then "accent" else "muted",
		title = "Wingman Live — click to toggle the panel",
		command = TOGGLE_ACTION,
		card = if #card > 0 then card else nil,
	}
end

-- What the widget and the panel show of the control plane; O(agents).
local function state_signature(b: Bridge): (string, string)
	local widget: { string } = {}
	for _, pane in sorted_panes() do
		table.insert(
			widget,
			string.format("%d:%s:%d:%s:%s", pane, states[pane], b.queued_dispatches(pane), b.fault(pane) or "", titles[pane] or "")
		)
	end
	local panel: { string } = {}
	local owners = b.owners()
	for worker, owner in owners do
		table.insert(panel, owner .. ">" .. worker)
	end
	table.sort(panel)
	for _, pane in sorted_panes() do
		table.insert(panel, string.format("%d:%d:%s", pane, b.queued_callbacks(pane), b.notified_waiting(pane) or ""))
	end
	local w = table.concat(widget, "|")
	return w, w .. "|" .. table.concat(panel, "|")
end

local function refresh_widget(sig: string)
	if sig ~= widget_sig then
		widget_sig = sig
		pcall(tern.chrome.refresh)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Data: agents, transcripts, git

local function collect(cx: WindowCx, b: Bridge): ({ Row }, { [number]: Row })
	local owner_of = b.owners()
	local workers_of: { [number]: { number } } = {}
	for worker, owner in owner_of do
		local list = workers_of[owner]
		if list == nil then
			list = {}
			workers_of[owner] = list
		end
		table.insert(list, worker)
	end
	for _, list in workers_of do
		table.sort(list)
	end
	local n0 = tern.now()
	local focused = cx.session:focused()
	local agents = cx.agents:list()
	native_ms += tern.now() - n0
	local all: { Row } = {}
	local all_by: { [number]: Row } = {}
	for _, a in agents do
		local n1 = tern.now()
		local info = cx.session:pane(a.pane)
		native_ms += tern.now() - n1
		if info ~= nil then
			track(a.pane, a.state, info.title, false)
			local model: any = a.model
			local command: any = a.command
			local title = if info.title ~= "" then info.title elseif type(command) == "string" then command else "agent"
			cwd_of[a.pane] = a.cwd
			local row: Row = {
				pane = a.pane,
				state = a.state :: string,
				title = title,
				model = if type(model) == "string" and model ~= "" then model else nil,
				cwd = a.cwd,
				tab = info.tab,
				floating = info.floating == true,
				parked = info.parked == true,
				place = nil,
				focused = a.pane == focused,
				owner = owner_of[a.pane],
				workers = workers_of[a.pane] or {},
				queued = b.queued_dispatches(a.pane),
				inbox = b.queued_callbacks(a.pane),
				fault = b.fault(a.pane),
				failed = finished[a.pane] == "failed",
			}
			table.insert(all, row)
			all_by[a.pane] = row
		end
	end
	-- Where an owner is: a shown agent's tab, else the native tab of a plain terminal (nil: parked or gone).
	local function owner_tab(owner: number): number?
		local row = all_by[owner]
		if row ~= nil then
			return row.tab
		end
		return cx.session:tab_of(owner)
	end
	-- Placement from the real pane state: parked wins, then a float, then another tab than the owner's.
	for _, r in all do
		if r.owner ~= nil then
			if r.parked then
				r.place = "parked"
			elseif r.floating then
				r.place = "pip"
			else
				local ot = owner_tab(r.owner)
				if r.tab ~= nil and ot ~= nil and r.tab ~= ot then
					r.place = "tab"
				end
			end
		end
	end
	local rows: { Row } = {}
	if scope == "all" then
		rows = all
	else
		-- The panel's tab (before it opens: the focused pane's, where it opens) as seeds: its agents and the plain
		-- terminals in it that own wingmen. Kept are every seed, all of its transitive wingmen (parked or in another
		-- tab), and its whole ancestry path up to the root, so a chain A→B→C stays connected. Siblings hanging off an
		-- out-of-tab ancestor are on no such path and stay out.
		local anchor = panel_pane or focused
		local tab = if anchor ~= nil then cx.session:tab_of(anchor) else nil
		local keep: { [number]: boolean } = {}
		if tab ~= nil then
			local function descend(id: number)
				if keep[id] then
					return
				end
				keep[id] = true
				local workers = workers_of[id]
				if workers then
					for _, w in workers do
						descend(w)
					end
				end
			end
			local seeds: { number } = {}
			for _, r in all do
				if r.tab == tab then
					table.insert(seeds, r.pane)
				end
			end
			for owner in workers_of do
				if all_by[owner] == nil and cx.session:tab_of(owner) == tab then
					table.insert(seeds, owner) -- a plain terminal owner
				end
			end
			for _, id in seeds do
				descend(id)
				-- Ancestry: a legacy binding cycle (no longer creatable) is cut by the visited set.
				local up: { [number]: boolean } = { [id] = true }
				local o = owner_of[id]
				while o ~= nil and not up[o] do
					up[o] = true
					keep[o] = true
					o = owner_of[o]
				end
			end
		end
		for _, r in all do
			if keep[r.pane] then
				table.insert(rows, r)
			end
		end
	end
	table.sort(rows, function(x: Row, y: Row): boolean
		return x.pane < y.pane
	end)
	local by_pane: { [number]: Row } = {}
	for _, r in rows do
		by_pane[r.pane] = r
	end
	return rows, by_pane
end

local function tool_path(t: { [string]: any }): string?
	local href = t.href
	if type(href) == "string" and string.sub(href, 1, 7) == "file://" then
		local p = string.match(string.sub(href, 8), "^[^#?]*") or ""
		p = string.gsub(p, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
		if string.match(p, "^/%a:") then
			p = string.sub(p, 2) -- file:///C:/… on Windows
		end
		return if p ~= "" then p else nil
	end
	if t.targetKind == "path" and type(t.target) == "string" then
		-- A read's line selector (`file.luau:50-80`, `:5,9`, `:-60`) names a range in the file, not another file.
		local p: string = string.gsub(t.target, ":[%d,%-+]+$", "")
		if HOME and string.sub(p, 1, 2) == "~/" then
			p = HOME .. string.sub(p, 2)
		end
		if string.sub(p, 1, 1) == "/" or string.match(p, "^%a:[/\\]") then
			return p
		end
	end
	return nil
end

local function mark_git_dirty(pane: number)
	local cwd = cwd_of[pane]
	local root = if cwd then roots_by_cwd[cwd] else nil
	if type(root) == "string" and repos[root] then
		repos[root].dirty = true
	end
end

local function tool_id(pane: number, t: { [string]: any }): string
	if type(t.key) == "string" and t.key ~= "" then
		return pane .. "|" .. t.key
	end
	-- Inline omp cards (reads) carry no key: the same call collapses with an identical one.
	return pane .. "|" .. tostring(t.name) .. "|" .. spans_text(t.target) .. "|" .. tostring(t.href)
end

local function tool_target(t: { [string]: any }): string
	local target = spans_text(t.target)
	if target == "" then
		target = spans_text(t.title)
	end
	if target == "" and type(t.intent) == "string" then
		target = t.intent
	end
	target = string.match(target, 'toolSummary="([^"]+)"') or target -- ACP run cards
	return clip(one_line(target), 160)
end

local function ingest(pane: number, msgs: { AgentMessage }, now_ms: number, cold: boolean)
	local list: { { [string]: any } } = {}
	local oldest_running: number? = nil -- message index of the oldest call still running
	for mi, m in msgs do
		for _, t in m.tools do
			table.insert(list, t)
			if oldest_running == nil and t.status == "running" then
				oldest_running = mi
			end
		end
	end
	local prev = window_ids[pane]
	local window: { [string]: boolean } = {}
	local n = #list
	for i, t in list do
		local id = tool_id(pane, t)
		window[id] = true
		local status = if type(t.status) == "string" then t.status else "done"
		local took = if type(t.took) == "number" and t.took > 0 then t.took else nil
		local rec = tools[id]
		if rec ~= nil then
			if rec.kind == "edit" and rec.status ~= status and status == "done" then
				mark_git_dirty(pane)
			end
			if rec.status == "running" then
				rec.target = tool_target(t) -- a running card fills in its target as it goes
			end
			rec.status, rec.took = status, took
		elseif prev == nil or not prev[id] then -- in the last window but not stored: evicted, not new
			local raw = if type(t.name) == "string" then t.name else "tool"
			local name = raw
			if raw == "tool" and type(t.title) == "string" and t.title ~= "" then
				name = t.title -- ACP: `run_command`, …
			end
			tool_seq += 1
			rec = {
				id = id,
				pane = pane,
				name = name,
				target = tool_target(t),
				kind = KIND[name] or KIND[raw] or "other",
				path = tool_path(t),
				status = status,
				took = took,
				-- A cold sample has no times: rank by distance from the newest, so panes interleave by recency.
				seen = if cold then now_ms - (n - i) else now_ms,
				exact = not cold,
				seq = tool_seq,
			}
			tools[id] = rec
			table.insert(tool_ids, id)
			if rec.kind == "edit" and status == "done" then
				mark_git_dirty(pane)
			end
		end
	end
	window_ids[pane] = window
	-- The next sample reaches back to the oldest running call, so its end is seen; one that escaped even the
	-- widest window can't be followed and stops claiming to run.
	local depth = if oldest_running then #msgs - oldest_running + 1 else 0
	sample_last[pane] = math.clamp(depth + WARM_MSGS, WARM_MSGS, MAX_MSGS)
	for _, id in tool_ids do
		local t = tools[id]
		if t.pane == pane and t.status == "running" and not window[id] then
			t.status = "lost"
		end
	end
	drop_tools(pane, TOOL_KEEP)
end

local function trip(reason: string, ms: number?)
	pause_ms = math.clamp(if pause_ms == 0 then PAUSE_MIN_MS else pause_ms * 2, PAUSE_MIN_MS, PAUSE_MAX_MS)
	mode = "lite"
	lite_until = tern.now() + math.max(pause_ms, ms or 0)
	lite_reason = reason
	tern.log.warn(string.format("wingman radar: %s; transcript sampling paused for %ds", reason, math.floor(pause_ms / 1000)))
end

-- Samples the transcripts that may have changed; stops once the render since `t0` nears SAFE_MS of Lua time.
local function sample(cx: WindowCx, rows: { Row }, t0: number)
	for _, r in rows do
		local cold = window_ids[r.pane] == nil
		if cold or tool_dirty[r.pane] or r.state == "working" then
			local n0 = tern.now()
			local ok, msgs = pcall(function(): { AgentMessage }
				return cx.agents:transcript(r.pane, { last = if cold then COLD_MSGS else sample_last[r.pane] or WARM_MSGS })
			end)
			native_ms += tern.now() - n0
			if ok then
				ingest(r.pane, msgs, tern.now(), cold)
				tool_dirty[r.pane] = nil
			end
			local wall = tern.now() - t0
			if wall - native_ms > SAFE_MS or wall > SAFE_WALL_MS then
				trip(string.format("sampling took %.1f ms Lua, %.1f ms wall", wall - native_ms, wall))
				return
			end
		end
	end
end

local schedule_render: () -> ()

local function flatten(st: GitStatus): { GitEntry }
	local by_path: { [string]: GitEntry } = {}
	local order: { GitEntry } = {}
	local function side(files: { GitFile }, key: string)
		for _, f in files do
			local e = by_path[f.path]
			if e == nil then
				e = { path = f.path, code = "", ins = 0, del = 0, conflict = false }
				by_path[f.path] = e
				table.insert(order, e)
			end
			local change: any = if key == "staged" then f.staged else f.unstaged
			if type(change) == "string" then
				e.code ..= CHANGE[change] or string.upper(string.sub(change, 1, 1))
			end
			local stat: any = if key == "staged" then f.staged_stat else f.unstaged_stat
			if type(stat) == "table" then
				e.ins += tonumber(stat[1]) or 0
				e.del += tonumber(stat[2]) or 0
			end
		end
	end
	side(st.staged, "staged")
	side(st.unstaged, "unstaged")
	for _, f in st.conflicts do
		local e = by_path[f.path]
		if e == nil then
			e = { path = f.path, code = "", ins = 0, del = 0, conflict = true }
			by_path[f.path] = e
			table.insert(order, e)
		end
		e.conflict = true
		e.code = "U"
	end
	return order
end

local function status_now(cx: WindowCx, repo: Repo)
	repo.inflight = true
	repo.dirty = false
	local started = tern.now()
	local promise = cx.git:status(repo.root)
	native_ms += tern.now() - started
	promise:next(function(st: GitStatus?, err: string?, _later: WindowCx?)
		repo.inflight = false
		local done = tern.now()
		-- A slow repo is asked less often, so its periodic status keeps under GIT_MAX_DUTY of the engine.
		repo.next_at = done + math.max(TICK_MIN_MS, (done - started) / GIT_MAX_DUTY)
		local ok, perr = try(function()
			if st then
				repo.files, repo.err = flatten(st), nil
			else
				repo.err = err or "git status failed"
			end
		end)
		if not ok then
			repo.err = "unreadable git status"
			log_once("git status", perr)
		end
		schedule_render()
	end)
end

-- Starts what git reads are due for the rows' repositories; returns their roots, most agents first.
local function kick_git(cx: WindowCx, rows: { Row }): { string }
	local count: { [string]: number } = {}
	local roots: { string } = {}
	local now_ms = tern.now()
	local catchup: number? = nil
	for _, r in rows do
		local root = roots_by_cwd[r.cwd]
		if root == nil and not cwd_inflight[r.cwd] and r.cwd ~= "" then
			local cwd = r.cwd
			cwd_inflight[cwd] = true
			local n0 = tern.now()
			local promise = cx.git:repo(cwd)
			native_ms += tern.now() - n0
			promise:next(function(repo: GitRepo?, _err: string?, _later: WindowCx?)
				cwd_inflight[cwd] = nil
				roots_by_cwd[cwd] = if repo then repo.root else false
				if repo then
					local known = repos[repo.root]
					if known then
						known.branch = repo.branch
					else
						repos[repo.root] = { root = repo.root, branch = repo.branch, inflight = false, dirty = true, next_at = 0 }
					end
				end
				schedule_render()
			end)
		elseif type(root) == "string" then
			if count[root] == nil then
				count[root] = 0
				table.insert(roots, root)
			end
			count[root] += 1
		end
	end
	for _, root in roots do
		local repo = repos[root]
		if repo and not repo.inflight then
			local due = repo.files == nil or (any_working and now_ms >= repo.next_at)
			if repo.dirty or due then
				if repo.files ~= nil and now_ms < repo.next_at then
					catchup = math.min(catchup or math.huge, repo.next_at - now_ms)
				else
					status_now(cx, repo)
				end
			end
		end
	end
	-- A dirty repo asked too recently gets one catch-up render when it may be asked again.
	if catchup ~= nil and catchup_handle == nil then
		catchup_handle = tern.timer(catchup, function(_later: WindowCx?)
			catchup_handle = nil
			schedule_render()
		end)
	end
	table.sort(roots, function(x: string, y: string): boolean
		return if count[x] ~= count[y] then count[x] > count[y] else x < y
	end)
	return roots
end

------------------------------------------------------------------------------------------------------------------------
-- View: plain node tables styled by the `radar` sheet. The `tern.ui.*` builders are native calls: measured ~6x the
-- cost and ~190 KB of garbage per 268-node build, against ~0 for the same tables built here.

local LOOM = 24 -- blocks in an agent's activity strip
local FEED_ROWS = 8 -- rows of the activity feed
local HOT_MS = 30000 -- a file touched this recently glows
local SEARCH: { [string]: boolean } = { grep = true, find = true, glob = true, ast_grep = true, search = true, lsp = true,
	grep_search = true, find_by_name = true, codebase_search = true }

local function el(tag: string, class: string?, kids: { Node }?, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.tag, p.class = tag, class
	return { k = "el", p = p, c = kids }
end

local function txt(tag: string, class: string?, text: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.tag, p.class, p.text = tag, class, text
	return { k = "el", p = p }
end

local function icon(name: string): Node
	return { k = "icon", p = { name = name } }
end

local function icon_btn(name: string, act: string, tip: string): Node
	return el("button", "wr-ib", { icon(name) }, { actions = { click = act }, title = tip, attrs = { ["aria-label"] = tip } })
end

local function hue(pane: number): string
	local h = hue_of[pane]
	if h == nil then
		h = next_hue % 6
		next_hue += 1
		hue_of[pane] = h
	end
	return tostring(h)
end

-- "fault" | "waiting" | "working" | "exited" | "idle": what the dot, the tiles and the stage's mood show.
local function state_of(r: Row): string
	local st: string = r.state
	local stalled = r.failed and st ~= "working"
	if r.fault ~= nil or stalled then
		return "fault"
	elseif st == "waiting_input" then
		return "waiting"
	elseif st == "working" or st == "exited" then
		return st
	end
	return "idle"
end

local function category(t: ToolRec): string
	if t.status == "error" or t.status == "failed" then
		return "error"
	elseif t.kind == "read" and SEARCH[t.name] then
		return "search"
	end
	return t.kind
end

local function running(t: ToolRec): boolean
	return t.status == "running" or t.status == "pending"
end

local function tool_dur(t: ToolRec, now_ms: number): string
	if running(t) then
		return (if t.exact then "" else "≥") .. fmt_dur(now_ms - t.seen)
	end
	return if t.took then fmt_dur(t.took) else ""
end

local function tool_label(t: ToolRec, roots: { string }): string
	return if t.path then clip_start(display_path(t.path, roots), 72) else clip(t.target, 72)
end

-- Each pane's tool records in call order.
local function tools_by_pane(by_pane: { [number]: Row }): { [number]: { ToolRec } }
	local out: { [number]: { ToolRec } } = {}
	for _, id in tool_ids do
		local t = tools[id]
		if by_pane[t.pane] ~= nil then
			local list = out[t.pane]
			if list == nil then
				list = {}
				out[t.pane] = list
			end
			table.insert(list, t)
		end
	end
	return out
end

local function kind_badge(t: ToolRec): Node
	return txt("span", "wr-k", clip(t.name, 14), { attrs = { ["data-k"] = category(t) } })
end

local function more_line(hidden: number): Node
	return txt("div", "wr-more", string.format("… %d more", hidden))
end

local function section_head(label: string, meta: string?): Node
	local kids = { txt("span", "wr-eyebrow", label) }
	if meta and meta ~= "" then
		table.insert(kids, txt("span", "wr-meta", meta))
	end
	return el("div", "wr-sh", kids)
end

-- One agent: its head row (focus target, chips, time, actions) and, while active, its current tool and strip.
local PLACE_TIP: { [string]: string } = {
	pip = "Floating over its owner",
	tab = "In a different tab than its owner",
	parked = "Parked: running but not on screen",
}

local function agent_parts(r: Row, ts: { ToolRec }?, roots: { string }, now_ms: number): { Node }
	local pane = tostring(r.pane)
	local s = state_of(r)
	local hit: { Node } = {
		el("span", "wr-dot", nil, { attrs = { ["data-s"] = s } }),
		txt("span", "wr-name", clip(r.title, 80), if r.focused then { attrs = { ["data-focused"] = true } } else nil),
		el("i", "wr-hue", nil, { attrs = { ["data-hue"] = hue(r.pane) } }),
	}
	if r.fault ~= nil then
		table.insert(hit, txt("span", "wr-chip", "fault", { attrs = { ["data-t"] = "bad" }, title = clip(r.fault, 400) }))
	end
	if r.queued > 0 then
		table.insert(hit, txt("span", "wr-chip", "Q" .. r.queued, { attrs = { ["data-t"] = "warn" }, title = "Prompts queued until this agent is idle" }))
	end
	if r.inbox > 0 then
		table.insert(hit, txt("span", "wr-chip", "↩" .. r.inbox, { title = "Wingman callbacks waiting for this agent to be idle" }))
	end
	local active = s == "working" or s == "waiting" or s == "fault"
	local when = if active
		then (if exact[r.pane] then "" else "≥") .. fmt_dur(now_ms - (since[r.pane] or now_ms))
		else (if exact[r.pane] then "" else "≤") .. os.date("%H:%M", since_wall[r.pane] or os.time())
	table.insert(hit, txt("span", "wr-time", when))
	local acts: { Node } = {}
	if r.place ~= nil then
		table.insert(hit, 4, txt("span", "wr-chip", r.place, { title = PLACE_TIP[r.place] }))
	end
	if r.parked then
		table.insert(acts, icon_btn("eye", "unpark=" .. pane, "Unpark: bring this parked wingman back into the current tab"))
	elseif r.floating then
		table.insert(acts, icon_btn("sidebar", "dock=" .. pane, "Dock this floating pane back into the split"))
	elseif r.owner ~= nil then
		table.insert(acts, icon_btn("pip", "pip=" .. pane, "Float this wingman in a corner of its owner"))
	end
	if r.owner ~= nil and not r.parked then
		table.insert(acts, icon_btn("eye-off", "park=" .. pane, "Park: hide this wingman (it keeps running)"))
	end
	if r.state == "working" then
		table.insert(acts, icon_btn("stop", "interrupt=" .. pane, "Interrupt: send Ctrl-C to this agent's turn"))
	elseif (r.fault ~= nil or r.failed) and r.state ~= "waiting_input" then
		table.insert(acts, icon_btn("refresh", "retry=" .. pane, "Retry: send /retry (F5) to this stalled agent"))
	end
	if r.queued > 0 then
		table.insert(acts, icon_btn("x", "unqueue=" .. pane, "Unqueue: cancel the prompts queued for this agent"))
	end
	local tip = string.format("Focus %s%s · pane %s\n%s", r.title, if r.model then " · " .. r.model else "", pane, r.cwd)
	local head: { Node } = { el("div", "wr-hit", hit, { actions = { click = "focus=" .. pane }, title = tip }) }
	if #acts > 0 then
		table.insert(head, el("div", "wr-acts", acts))
	end
	local parts: { Node } = { el("div", "wr-row", head) }
	if active and ts and #ts > 0 then
		local cur = ts[#ts]
		for i = #ts, 1, -1 do
			if running(ts[i]) then
				cur = ts[i]
				break
			end
		end
		table.insert(parts, el("div", "wr-tool", {
			kind_badge(cur),
			txt("span", "wr-tgt", tool_label(cur, roots)),
			txt("span", "wr-time", tool_dur(cur, now_ms)),
		}, { actions = { click = "focus=" .. pane }, title = cur.target }))
		local blocks: { Node } = {}
		for i = math.max(1, #ts - LOOM + 1), #ts do
			local t = ts[i]
			local a: { [string]: any } = { ["data-k"] = category(t) }
			if running(t) then
				a["data-run"] = true
			end
			local dur = tool_dur(t, now_ms)
			table.insert(blocks, el("i", "wr-b", nil, {
				attrs = a,
				title = t.name .. " " .. basename(tool_label(t, roots)) .. (if dur ~= "" then " · " .. dur else ""),
			}))
		end
		table.insert(parts, el("div", "wr-loom", blocks))
	end
	return parts
end

-- Each owner as a card with its wingmen on a rail (a wingman may own others in turn), then agents nobody owns.
local function topology(rows: { Row }, by_pane: { [number]: Row }, by_tool: { [number]: { ToolRec } }, roots: { string }, now_ms: number, budget: Budget): Node
	local kids: { Node } = {}
	local hidden = 0
	local placed: { [number]: boolean } = {}
	local chain: (r: Row) -> { Node }
	chain = function(r: Row): { Node }
		placed[r.pane] = true
		local parts = agent_parts(r, by_tool[r.pane], roots, now_ms)
		local rail: { Node } = {}
		for _, id in r.workers do
			local child = by_pane[id]
			if child ~= nil and not placed[child.pane] then
				table.insert(rail, el("div", "wr-wm", chain(child)))
			end
		end
		if #rail > 0 then
			table.insert(parts, el("div", "wr-kids", rail))
		end
		return parts
	end
	local function add(head: Row)
		local n = el("div", "wr-card", chain(head), { key = "a" .. head.pane })
		if hidden == 0 and fits(budget, n) then
			table.insert(kids, n)
		else
			hidden += 1
		end
	end
	for _, r in rows do
		if r.owner == nil or by_pane[r.owner] == nil then
			add(r)
		end
	end
	for _, r in rows do
		if not placed[r.pane] then
			add(r) -- defensive, legacy only: a stored binding cycle has no head (native now rejects new ones)
		end
	end
	if #rows == 0 then
		table.insert(kids, txt("div", "wr-empty", if scope == "tab" then "No agents in this tab — switch to All above." else "No agents."))
	end
	if hidden > 0 then
		table.insert(kids, more_line(hidden))
	end
	local bound = 0
	for _, r in rows do
		if r.owner ~= nil and by_pane[r.owner] then
			bound += 1
		end
	end
	return el("div", "wr-sec", { section_head("Agents", string.format("%d · %d bound", #rows, bound)), el("div", "wr-cards", kids) })
end

-- Diff bar width bucket: log4 of the line count, 1–6.
local function bucket(n: number): string?
	if n <= 0 then
		return nil
	end
	return tostring(math.min(6, 1 + math.floor(math.log(n) / math.log(4))))
end

local function file_row(f: FileRow, name: string, now_ms: number): Node
	local code = f.code
	local st = if code ~= nil and code ~= "" then string.sub(code, 1, 1) else "·"
	local kids: { Node } = {
		txt("span", "wr-st", st, { attrs = { ["data-s"] = if f.conflict then "U" else st } }),
		txt("span", "wr-fn", name),
	}
	if now_ms - f.last < HOT_MS then
		table.insert(kids, el("i", "wr-hot"))
	end
	local who: { Node } = {}
	for pane in f.panes do
		if #who < 4 then
			table.insert(who, el("i", "wr-hue", nil, { attrs = { ["data-hue"] = hue(pane) } }))
		end
	end
	if #who > 0 then
		table.insert(kids, el("span", "wr-who", who))
	end
	if f.ins + f.del > 0 then
		local bar: { Node } = {}
		local a, d = bucket(f.ins), bucket(f.del)
		if a then
			table.insert(bar, el("i", "wr-a", nil, { attrs = { ["data-w"] = a } }))
		end
		if d then
			table.insert(bar, el("i", "wr-d", nil, { attrs = { ["data-w"] = d } }))
		end
		table.insert(kids, el("span", "wr-bar", bar))
		table.insert(kids, el("span", "wr-ln", {
			txt("span", "wr-add", if f.ins > 0 then "+" .. f.ins else ""),
			txt("span", "wr-del", if f.del > 0 then " −" .. f.del else ""),
		}))
	end
	local touch: { string } = {}
	if f.edits > 0 then
		table.insert(touch, string.format("%d edit%s", f.edits, if f.edits == 1 then "" else "s"))
	end
	if f.reads > 0 then
		table.insert(touch, string.format("%d read%s", f.reads, if f.reads == 1 then "" else "s"))
	end
	return el("div", "wr-file", kids, {
		key = "f" .. f.abs,
		motionKey = "f" .. f.abs,
		actions = { click = "open=" .. f.abs },
		title = f.abs .. (if #touch > 0 then "\n" .. table.concat(touch, " · ") else ""),
		attrs = { ["data-read"] = if code == nil and f.edits == 0 then true else nil },
	})
end

local function living_files(by_pane: { [number]: Row }, roots: { string }, now_ms: number, budget: Budget): Node
	local files: { [string]: FileRow } = {}
	local list: { FileRow } = {}
	local function entry(abs: string): FileRow
		local f = files[abs]
		if f == nil then
			f = { abs = abs, code = nil, ins = 0, del = 0, conflict = false, edits = 0, reads = 0, last = -math.huge, panes = {} }
			files[abs] = f
			table.insert(list, f)
		end
		return f
	end
	local heads: { Node } = {}
	for _, root in roots do
		local repo = repos[root]
		if repo then
			local ins, del = 0, 0
			local changed = repo.files
			if changed then
				for _, g in changed do
					local f = entry(root .. "/" .. g.path)
					f.code, f.ins, f.del, f.conflict = g.code, g.ins, g.del, g.conflict
					ins += g.ins
					del += g.del
				end
			end
			local tail: Node = if repo.err
				then txt("span", "wr-meta", "git error", { title = repo.err })
				elseif changed == nil then txt("span", "wr-meta", "scanning…")
				else el("span", "wr-ln", { txt("span", "wr-add", "+" .. ins), txt("span", "wr-del", " −" .. del) }, { title = #changed .. " changed" })
			local kids = { icon("git-branch") }
			if repo.branch then
				table.insert(kids, txt("span", "wr-br", clip(repo.branch, 28)))
			end
			table.insert(kids, txt("span", "wr-repo-n", basename(root), { title = root }))
			table.insert(kids, tail)
			table.insert(heads, el("div", "wr-repo", kids))
		end
	end
	for _, id in tool_ids do
		local t = tools[id]
		if t.path ~= nil and by_pane[t.pane] ~= nil and (t.kind == "edit" or (t.kind == "read" and not cleared[id])) then
			local f = entry(t.path)
			if t.kind == "edit" then
				f.edits += 1
			else
				f.reads += 1
			end
			f.panes[t.pane] = true
			f.last = math.max(f.last, t.seen)
		end
	end
	-- Which files show: conflicts, then touched changes, then changes, then reads, newest first. How they show:
	-- by directory, then name, so rows only move when one comes or goes.
	local function rank(f: FileRow): number
		if f.conflict then
			return 3
		elseif f.edits > 0 or (f.code ~= nil and f.reads > 0) then
			return 2
		elseif f.code ~= nil then
			return 1
		end
		return 0
	end
	table.sort(list, function(x: FileRow, y: FileRow): boolean
		local rx, ry = rank(x), rank(y)
		if rx ~= ry then
			return rx > ry
		elseif x.last ~= y.last then
			return x.last > y.last
		end
		return x.abs < y.abs
	end)
	type Shown = { f: FileRow, dir: string, name: string, node: Node }
	local shown: { Shown } = {}
	local hidden = 0
	for _, f in list do
		if hidden > 0 or #shown >= FILE_ROWS then
			hidden += 1
			continue
		end
		local path = display_path(f.abs, roots)
		local dir, name = string.match(path, "^(.*[/\\])([^/\\]+)$")
		local n = file_row(f, name or path, now_ms)
		if fits(budget, n) then
			table.insert(shown, { f = f, dir = dir or "", name = name or path, node = n })
		else
			hidden += 1
		end
	end
	table.sort(shown, function(x: Shown, y: Shown): boolean
		return if x.dir ~= y.dir then x.dir < y.dir else x.name < y.name
	end)
	local body: { Node } = {}
	local group: { Node }? = nil
	local group_dir: string? = nil
	for _, s in shown do
		if s.dir ~= group_dir or group == nil then
			group_dir = s.dir
			if s.dir ~= "" then
				table.insert(body, txt("div", "wr-dir", clip_start(s.dir, 64), { title = s.dir }))
			end
			local g: { Node } = {}
			group = g
			table.insert(body, el("div", "wr-files", g, { key = "d" .. s.dir, transition = "layout" }))
		end
		table.insert(group :: { Node }, s.node)
	end
	if #list == 0 then
		table.insert(body, txt("div", "wr-empty", "No changed or recently touched files."))
	end
	if hidden > 0 then
		table.insert(body, more_line(hidden))
	end
	local kids: { Node } = { section_head("Living files", if #list > 0 then tostring(#list) else nil) }
	for _, h in heads do
		table.insert(kids, h)
	end
	table.insert(kids, el("div", nil, body))
	return el("div", "wr-sec", kids)
end

local function activity(by_pane: { [number]: Row }, roots: { string }, now_ms: number, budget: Budget): Node
	local list: { ToolRec } = {}
	for _, id in tool_ids do
		local t = tools[id]
		if by_pane[t.pane] ~= nil then
			table.insert(list, t)
		end
	end
	table.sort(list, function(x: ToolRec, y: ToolRec): boolean
		return if x.seen ~= y.seen then x.seen > y.seen else x.seq > y.seq
	end)
	local kids: { Node } = {}
	for _, t in list do
		if #kids >= FEED_ROWS then
			break
		end
		local a: { [string]: any }? = if running(t) then { ["data-run"] = true } elseif t.status == "lost" then { ["data-lost"] = true } else nil
		local n = el("div", "wr-act", {
			el("i", "wr-hue", nil, { attrs = { ["data-hue"] = hue(t.pane) } }),
			kind_badge(t),
			txt("span", "wr-tgt", tool_label(t, roots)),
			txt("span", "wr-time", tool_dur(t, now_ms)),
		}, {
			key = "t" .. t.seq,
			actions = { click = "focus=" .. t.pane },
			title = t.target .. "\nFocus " .. (titles[t.pane] or ("pane " .. t.pane)),
			attrs = a,
		})
		if not fits(budget, n) then
			break
		end
		table.insert(kids, n)
	end
	if mode == "lite" then
		local left = math.max(0, math.ceil((lite_until - now_ms) / 1000))
		table.insert(kids, 1, txt("div", "wr-warn", string.format("Sampling paused (%s) — resumes in %ds", lite_reason, left)))
	end
	if #list == 0 then
		table.insert(kids, txt("div", "wr-empty", "No tool calls yet."))
	end
	return el("div", "wr-sec", { section_head("Activity", if #list > 0 then "last " .. math.min(#list, FEED_ROWS) else nil), el("div", nil, kids) })
end

local function stage(rows: { Row }): Node
	local working, waiting, queued, faults = 0, 0, 0, 0
	for _, r in rows do
		local s = state_of(r)
		if s == "working" then
			working += 1
		elseif s == "waiting" then
			waiting += 1
		elseif s == "fault" then
			faults += 1
		end
		queued += r.queued
	end
	local mood = if faults > 0 then "fault" elseif waiting > 0 then "waiting" elseif working > 0 then "working" else "idle"
	local function tile(n: number, label: string, k: string): Node
		return el("div", "wr-tile", {
			txt("span", "wr-n", tostring(n)),
			txt("span", "wr-tl", label),
		}, { attrs = { ["data-k"] = k, ["data-zero"] = if n == 0 then true else nil } })
	end
	local function seg(label: string, value: Scope, tip: string): Node
		return txt("button", "wr-sb", label, {
			actions = { click = "scope=" .. value },
			title = tip,
			attrs = { ["data-on"] = if scope == value then true else nil, ["aria-pressed"] = if scope == value then "true" else "false" },
		})
	end
	local floating = placement == "float"
	return el("div", "wr-stage", {
		el("div", "wr-top", {
			txt("span", "wr-eyebrow", "Wingman · live"),
			el("div", "wr-seg", {
				seg("Tab", "tab", "Agents in this panel's tab and their bound partners"),
				seg("All", "all", "Every agent in this window"),
			}, { attrs = { role = "group" } }),
			icon_btn(
				if floating then "sidebar" else "pip",
				if floating then "place=right" else "place=float",
				if floating then "Dock as the right sidebar" else "Float over the right pane"
			),
		}),
		el("div", "wr-tiles", {
			tile(working, "working", "working"),
			tile(waiting, "waiting", "waiting"),
			tile(queued, "queued", "queued"),
			tile(faults, "faults", "fault"),
		}),
	}, { attrs = { ["data-mood"] = mood } })
end

local function dock_node(): Node
	local kids: { Node } = {
		el("button", "wr-btn", { icon("git-branch"), txt("span", nil, "Open Git") }, {
			actions = { click = "git" },
			title = "Open the git block of the main repository in scope",
		}),
		el("button", "wr-btn", { icon("eraser"), txt("span", nil, "Clear reads") }, {
			actions = { click = "clear" },
			title = "Hide the read/search touches shown so far",
		}),
	}
	if mode == "lite" then
		table.insert(kids, txt("span", "wr-lite", "lite", { title = "Transcript sampling paused: " .. lite_reason }))
	end
	table.insert(kids, el("span", "wr-health", nil, {
		attrs = { ["data-mode"] = mode },
		title = string.format(
			"%s · %.1f ms Lua / %.1f ms wall · %d nodes · %d KB\nRender #%d, ms per phase: %s\nBudget: %d ms Lua a call (radar keeps under %d)",
			mode,
			last_lua,
			last_wall,
			last_nodes,
			math.ceil(last_bytes / 1024),
			renders,
			last_phases,
			BUDGET_MS,
			SAFE_MS
		),
	}))
	return { k = "col", p = { role = ROLE .. ".dock" }, c = { el("div", "wr-dock", kids) } }
end

-- Collects, samples, starts git reads and builds the view within `node_cap` nodes; `phases` gets each step's
-- "wall/native" ms.
local function compose(cx: WindowCx, b: Bridge, t0: number, phases: { string }): (Node, Node, number, number)
	local t, nat = t0, native_ms
	local function lap(name: string)
		local now = tern.now()
		table.insert(phases, string.format("%s %.1f/%.1f", name, now - t, native_ms - nat))
		t, nat = now, native_ms
	end
	local rows, by_pane = collect(cx, b)
	any_working = false
	for _, r in rows do
		if r.state == "working" then
			any_working = true
		end
	end
	lap("collect")
	if mode == "lite" and t0 >= lite_until then
		mode = "rich"
	end
	if mode == "rich" then
		sample(cx, rows, t0)
	end
	lap("sample")
	local roots = kick_git(cx, rows)
	primary_root = roots[1]
	lap("git")
	-- Keyboard moves and other plugins' calls fire no `float_moved`: the toggle follows what the panel is now.
	local self_pane = panel_pane
	if self_pane ~= nil then
		local info = cx.session:pane(self_pane)
		if info ~= nil then
			placement = if info.floating then "float" else "right"
		end
	end
	local now_ms = tern.now()
	local function build(cap: number): (Node, Node, number)
		local avail = cap - 60 -- stage, section heads and dock
		local by_tool = tools_by_pane(by_pane)
		local topo = topology(rows, by_pane, by_tool, roots, now_ms, { left = math.floor(avail * 0.45) })
		lap("topo")
		local used = count_nodes(topo)
		local files = living_files(by_pane, roots, now_ms, { left = math.floor((avail - used) * 0.75) })
		lap("files")
		used += count_nodes(files)
		local feed = activity(by_pane, roots, now_ms, { left = avail - used })
		lap("tools")
		local view: Node = { k = "col", p = { role = ROLE }, c = { el("div", "wr", { stage(rows), topo, files, feed }) } }
		local dock = dock_node()
		return view, dock, count_nodes(view) + count_nodes(dock)
	end
	local view, dock, nodes = build(node_cap)
	lap("build")
	local n0 = tern.now()
	local bytes = #tern.json.encode({ view, dock })
	native_ms += tern.now() - n0
	if bytes > BYTE_CAP then
		-- Long texts: shrink the node budget by the overshoot and rebuild once.
		node_cap = math.max(NODE_FLOOR, math.floor(node_cap * BYTE_CAP / bytes))
		view, dock, nodes = build(node_cap)
		local n1 = tern.now()
		bytes = #tern.json.encode({ view, dock })
		native_ms += tern.now() - n1
	end
	lap("encode")
	return view, dock, nodes, bytes
end

local function cancel_timers()
	local tick = tick_handle
	tick_handle = nil
	if tick then
		tick:cancel()
	end
	local catchup = catchup_handle
	catchup_handle = nil
	if catchup then
		catchup:cancel()
	end
end

-- The panel closed: stop its timers and drop its tool records (git dedupe state stays, bounded by repos).
local function forget_panel()
	panel_pane = nil
	render_armed = false
	cancel_timers()
	tools, tool_ids, window_ids, sample_last, tool_dirty, cleared = {}, {}, {}, {}, {}, {}
	any_working = false
end

local function adapt(wall: number, nodes: number, bytes: number, phases: { string })
	local lua = math.max(0, wall - native_ms)
	last_wall, last_lua, last_nodes, last_bytes = wall, lua, nodes, bytes
	renders += 1
	last_phases = table.concat(phases, " · ") .. string.format(" · native %.1f", native_ms)
	if lua > SAFE_MS or wall > SAFE_WALL_MS then
		if mode == "rich" then
			trip(string.format("render took %.1f ms Lua, %.1f ms wall", lua, wall))
		else
			-- Lite and still over: the view itself is heavy, so shrink it in proportion.
			local scale = math.min(SAFE_MS / math.max(lua, SAFE_MS), SAFE_WALL_MS / math.max(wall, SAFE_WALL_MS))
			node_cap = math.max(NODE_FLOOR, math.floor(node_cap * scale))
		end
	elseif mode == "rich" then
		pause_ms = 0
		if lua < SAFE_MS / 2 and wall < SAFE_WALL_MS / 2 and node_cap < NODE_CAP then
			node_cap = math.min(NODE_CAP, math.floor(node_cap * 1.25))
		end
	end
end

-- Where each bound pane really is (tab, parked, floating) and where its owner is; O(bound panes) native reads.
local function placement_sig(cx: WindowCx, b: Bridge): string
	local parts: { string } = {}
	for worker, owner in b.owners() do
		local info = cx.session:pane(worker)
		table.insert(parts, string.format(
			"%d:%d:%s:%s:%s:%s",
			worker,
			owner,
			tostring(if info ~= nil then info.tab else nil),
			tostring(info ~= nil and info.parked == true),
			tostring(info ~= nil and info.floating == true),
			tostring(cx.session:tab_of(owner))
		))
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

local render: (cx: WindowCx) -> ()

local function arm_tick()
	if tick_handle ~= nil or panel_pane == nil or not any_working then
		return
	end
	tick_handle = tern.timer(math.max(TICK_MIN_MS, last_wall / MAX_DUTY), function(later: WindowCx?)
		tick_handle = nil
		if later ~= nil then
			render(later)
		end
	end)
end

render = function(cx: WindowCx)
	local b = bridge
	local pane = panel_pane
	if b == nil or pane == nil then
		return
	end
	local sig_ok, sig = pcall(placement_sig, cx, b)
	if sig_ok then
		placement_last = sig
	end
	local ok, err = try(function()
		native_ms = 0
		local phases: { string } = {}
		local t0 = tern.now()
		local view, dock, nodes, bytes = compose(cx, b, t0, phases)
		local n0 = tern.now()
		cx.canvas:set(pane, { view = view, dock = dock })
		local set_ms = tern.now() - n0
		native_ms += set_ms
		table.insert(phases, string.format("set %.1f", set_ms))
		adapt(tern.now() - t0, nodes, bytes, phases)
	end)
	if not ok then
		if cx.canvas:get(pane) == nil then
			-- Not in this window's replica: a canvas opened earlier in this same call (a re-dock) shows up in the
			-- next one. A closed panel is dropped by `pane_closed`, which also stops this retry.
			if panel_pane == pane then
				schedule_render()
			end
			return
		end
		log_once("render", err)
	end
	arm_tick()
end

schedule_render = function()
	if panel_pane == nil or render_armed then
		return
	end
	render_armed = true
	tern.timer(0, function(later: WindowCx?)
		render_armed = false
		if later ~= nil then
			render(later)
		end
	end)
end

-- Layout-only operations (pip, dock, park, unpark, tab moves) change no signature `state_signature` reads and raise no
-- native event. A coalesced check reads only the bound panes' placement and renders just when it differs.
schedule_layout_render = function()
	if panel_pane == nil or layout_armed then
		return
	end
	layout_armed = true
	tern.timer(0, function(later: WindowCx?)
		layout_armed = false
		local b = bridge
		if later == nil or b == nil or panel_pane == nil then
			return
		end
		local ok, sig = pcall(placement_sig, later, b)
		if ok and sig ~= placement_last then
			render(later)
		end
	end)
end

------------------------------------------------------------------------------------------------------------------------
-- Panel lifecycle and actions

-- Takes over a panel Tern kept across a reload; closes duplicates.
local function adopt(cx: WindowCx)
	local pane = panel_pane
	if pane ~= nil and cx.canvas:get(pane) ~= nil then
		return
	end
	panel_pane = nil
	for _, info in cx.canvas:list() do
		if info.owner == tern.plugin.id and info.title == TITLE then
			if panel_pane == nil then
				panel_pane = info.pane
			else
				local extra = info.pane
				pcall(function()
					cx.layout:close(extra)
				end)
			end
		end
	end
end

local function save_prefs()
	pcall(function()
		tern.kv.set(KV_RADAR, { scope = scope, placement = placement, corner = corner })
	end)
end

-- The rightmost tiled leaf under `node` other than `skip`, and its share of the tab's width: a right split gives
-- its second child `1 - ratio` of the width, a down split gives both children all of it.
local function rightmost(node: TabTree, share: number, skip: number?): (number?, number)
	local leaf = node.pane
	if leaf ~= nil then
		return if leaf == skip then nil else leaf, share
	end
	local first, second = node[1], node[2]
	local ratio = node.ratio or 0.5
	if node.split == "right" then
		if second ~= nil then
			local p, s = rightmost(second, share * (1 - ratio), skip)
			if p ~= nil then
				return p, s
			end
		end
		if first ~= nil then
			return rightmost(first, share * ratio, skip)
		end
	else
		if first ~= nil then
			local p, s = rightmost(first, share, skip)
			if p ~= nil then
				return p, s
			end
		end
		if second ~= nil then
			return rightmost(second, share, skip)
		end
	end
	return nil, share
end

-- Where the sidebar goes in the focused pane's tab: beside its rightmost leaf, at the split share that makes it
-- TAB_SHARE of the tab's width (kept within RATIO_MIN..RATIO_MAX of the leaf it splits).
local function right_edge(cx: WindowCx, skip: number?): (number?, number)
	local focused = cx.session:focused()
	local tab = if focused ~= nil then cx.session:tab_of(focused) else nil
	local layout = if tab ~= nil then cx.session:layout(tab) else nil
	if layout == nil then
		return nil, TAB_SHARE
	end
	local pane, share = rightmost(layout.root, 1, skip)
	return pane, math.clamp(TAB_SHARE / math.max(share, 0.01), RATIO_MIN, RATIO_MAX)
end

local function float_panel(cx: WindowCx, pane: number): (boolean, string?)
	local over = right_edge(cx, pane)
	return cx.layout:float(pane, over, corner, { focus = false, size = FLOAT_SIZE })
end

-- `pane`'s share of its tab's width, or nil when it isn't tiled there.
local function share_of(cx: WindowCx, pane: number): number?
	local tab = cx.session:tab_of(pane)
	local layout = if tab ~= nil then cx.session:layout(tab) else nil
	if layout == nil then
		return nil
	end
	local function walk(node: TabTree, share: number): number?
		if node.pane ~= nil then
			return if node.pane == pane then share else nil
		end
		local ratio = node.ratio or 0.5
		local horizontal = node.split == "right"
		local first, second = node[1], node[2]
		local found: number? = nil
		if first ~= nil then
			found = walk(first, if horizontal then share * ratio else share)
		end
		if found == nil and second ~= nil then
			found = walk(second, if horizontal then share * (1 - ratio) else share)
		end
		return found
	end
	return walk(layout.root, 1)
end

-- A sidebar split from a narrow rightmost pane gets less than TAB_SHARE. Tern reports no widths in cells, so take
-- the rest from the group on the left of the panel's group: probe-shrink that group's rightmost leaf (its edge is
-- the divider), read how far that moved the panel's share, and shrink it by the cells the rest needs.
local WIDEN_PROBE = 4
local function widen(cx: WindowCx, pane: number)
	local before = share_of(cx, pane)
	local tab = cx.session:tab_of(pane)
	local layout = if tab ~= nil then cx.session:layout(tab) else nil
	if before == nil or layout == nil or before >= TAB_SHARE * 0.95 then
		return
	end
	-- The path to the panel; the last step is its own split (the leaf it was opened beside, then the panel).
	local path: { { node: TabTree, side: number } } = {}
	local function find(node: TabTree): boolean
		if node.pane ~= nil then
			return node.pane == pane
		end
		for side = 1, 2 do
			local child = node[side]
			if child ~= nil then
				table.insert(path, { node = node, side = side })
				if find(child) then
					return true
				end
				table.remove(path)
			end
		end
		return false
	end
	if not find(layout.root) then
		return
	end
	local left: number? = nil
	for i = #path - 1, 1, -1 do
		local step = path[i]
		if step.node.split == "right" and step.side == 2 then
			left = rightmost(step.node[1], 1, nil)
			break
		end
	end
	if left == nil or not cx.layout:resize(left, "right", -WIDEN_PROBE) then
		return -- nothing on the left (a one-pane tab: the ratio is already exact)
	end
	local after = share_of(cx, pane)
	if after == nil or after <= before then
		return
	end
	local cells = math.floor((TAB_SHARE - after) / ((after - before) / WIDEN_PROBE) + 0.5)
	if cells > 0 then
		cx.layout:resize(left, "right", -cells)
	end
end

local function open_panel(cx: WindowCx, b: Bridge)
	native_ms = 0
	local phases: { string } = {}
	local t0 = tern.now()
	local view, dock, nodes, bytes = compose(cx, b, t0, phases)
	local n0 = tern.now()
	local target, ratio = right_edge(cx, nil)
	local spec: CanvasSpec = { title = TITLE, about = ABOUT, view = view, dock = dock, how = "beside", focus = false }
	if target ~= nil then
		spec.target, spec.dir, spec.ratio = target, "right", ratio
	end
	local pane, err = cx.canvas:open(spec)
	if pane ~= nil and placement == "float" then
		local ok, ferr = float_panel(cx, pane)
		if not ok then
			log_once("float", ferr)
		end
	elseif pane ~= nil and target ~= nil then
		local opened = pane
		local ok, werr = try(function()
			widen(cx, opened)
		end)
		if not ok then
			log_once("widen", werr)
		end
	end
	local open_ms = tern.now() - n0
	native_ms += open_ms
	if pane == nil then
		cx:toast("error", "Wingman Live didn't open", err)
		return
	end
	panel_pane = pane
	table.insert(phases, string.format("open %.1f", open_ms))
	adapt(tern.now() - t0, nodes, bytes, phases)
	arm_tick()
end

local function toggle(cx: WindowCx)
	local b = bridge
	if b == nil then
		return
	end
	adopt(cx)
	local pane = panel_pane
	if pane ~= nil then
		forget_panel()
		pcall(function()
			cx.layout:close(pane)
		end)
		return
	end
	open_panel(cx, b)
end

-- Float ↔ right sidebar. Docking reopens the canvas at the right edge (`dock` can't set its width); the tool
-- records stay, so nothing is resampled cold.
local function place(cx: WindowCx, b: Bridge, want: Placement)
	local pane = panel_pane
	placement = want
	save_prefs()
	if pane == nil then
		return
	end
	if want == "float" then
		local ok, err = float_panel(cx, pane)
		if not ok then
			cx:toast("error", "Wingman Live couldn't float", err)
		end
	else
		panel_pane = nil -- its pane_closed is then no longer the panel's
		pcall(function()
			cx.layout:close(pane)
		end)
		open_panel(cx, b)
	end
end

local function handle_action(ev: CanvasAction, cx: WindowCx, b: Bridge)
	local act: string, value: string = ev.act, ev.value or ""
	if value == "" then
		-- Clicks arrive split at `=`; an action sent with `cx.session:event` (Carly, `wingman.py event`) doesn't.
		local a, v = string.match(act, "^([^=]+)=(.*)$")
		if a and v then
			act, value = a, v
		end
	end
	local pane = tonumber(value)
	local pick_scope: Scope? = if value == "tab" then "tab" elseif value == "all" then "all" else nil
	local want: Placement? = if value == "float" then "float" elseif value == "right" then "right" else nil
	local function report(ok: boolean, err: string?, what: string)
		if not ok then
			cx:toast("error", "Wingman: " .. what .. " failed", err)
		end
	end
	if act == "focus" and pane then
		cx.layout:focus(pane)
	elseif act == "pip" and pane then
		local ok, err = b.pip(cx, pane)
		report(ok, err, "PiP")
	elseif act == "dock" and pane then
		local ok, err = b.dock(cx, pane)
		report(ok, err, "Dock")
	elseif act == "interrupt" and pane then
		local ok, err = b.interrupt(cx, pane)
		report(ok, err, "Interrupt")
	elseif act == "retry" and pane then
		local ok, err = b.retry(cx, pane)
		report(ok, err, "Retry")
		if ok then
			finished[pane] = nil
		end
	elseif act == "unqueue" and pane then
		local n = b.unqueue(cx, pane)
		cx:toast("info", string.format("Wingman: cancelled %d queued prompt%s", n, if n == 1 then "" else "s"), titles[pane])
	elseif act == "open" and value ~= "" then
		cx:open(value, "beside")
	elseif act == "park" and pane then
		local ok, err = b.park(cx, pane)
		report(ok, err, "Park")
	elseif act == "unpark" and pane then
		local ok, err = b.unpark(cx, pane)
		report(ok, err, "Unpark")
	elseif act == "scope" and pick_scope ~= nil then
		scope = pick_scope
		save_prefs()
	elseif act == "place" and want ~= nil then
		place(cx, b, want)
	elseif act == "git" then
		local root = primary_root
		if root == nil then
			cx:toast("info", "Wingman: no git repository among the agents in scope")
		else
			cx.git:open(root, { how = "beside" }):next(function(_pane: number?, err: string?, later: WindowCx?)
				if err and later then
					later:toast("error", "Wingman: Open Git failed", err)
				end
			end)
		end
	elseif act == "clear" then
		for _, id in tool_ids do
			if tools[id].kind == "read" then
				cleared[id] = true
			end
		end
	else
		log_once("unknown action", string.format("%s=%s on node %s", act, value, ev.node))
	end
end

local function on_canvas_action(ev: CanvasAction, cx: WindowCx): boolean
	-- `title` is optional on the event: without one, the panel's pane identifies it.
	local ours = if ev.title ~= nil then ev.title == TITLE else ev.pane == panel_pane
	if ev.owner ~= tern.plugin.id or not ours then
		return false
	end
	local b = bridge
	if b == nil then
		return true
	end
	panel_pane = ev.pane
	local ok, err = try(function()
		handle_action(ev, cx, b)
	end)
	if not ok then
		log_once("action " .. ev.act, err)
	end
	-- A click redraws at once: a timer armed in a handler would wait for the plugin's next poll.
	render(cx)
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- Events

local function seed(cx: WindowCx)
	for _, a in cx.agents:list() do
		local info = cx.session:pane(a.pane)
		if info ~= nil then
			track(a.pane, a.state, info.title, false)
		end
	end
	local b = bridge
	if b then
		local widget, panel = state_signature(b)
		change_sig = panel
		refresh_widget(widget)
	end
	adopt(cx)
	if panel_pane ~= nil then
		render(cx)
	end
end

local M = {}

--- window.luau calls this (in a pcall) after its state may have moved: RPC requests, watchdog steps, binding and
--- escalation changes. O(agents); a render is scheduled only when an open panel shows something that changed.
function M.on_state_change()
	local b = bridge
	if b == nil then
		return
	end
	local widget, panel = state_signature(b)
	refresh_widget(widget)
	if panel ~= change_sig then
		change_sig = panel
		schedule_render()
	elseif panel_pane ~= nil then
		-- Layout-only operations (pip, dock, park, unpark, tab moves) change no signature above and raise no native
		-- event of their own; the open panel re-reads placements, throttled to the tick's spacing.
		schedule_layout_render()
	end
end

--- Registers the panel's command, widget and handlers. window.luau calls it after its own handlers, so radar's run
--- after the control plane's for the same event.
function M.attach(b: Bridge)
	if bridge ~= nil then
		return
	end
	bridge = b
	pcall(tern.css, "radar", CSS)
	local ok_kv, saved = pcall(tern.kv.get, KV_RADAR)
	if ok_kv and type(saved) == "table" then
		if saved.scope == "tab" or saved.scope == "all" then
			scope = saved.scope
		end
		if saved.placement == "right" or saved.placement == "float" then
			placement = saved.placement
		end
		if saved.corner == "tl" or saved.corner == "tr" or saved.corner == "bl" or saved.corner == "br" then
			corner = saved.corner
		end
	end

	tern.command({
		id = "toggle_panel",
		title = "Wingman: Toggle Live Panel",
		icon = "activity",
		run = function(cx: WindowCx)
			local ok, err = try(function()
				toggle(cx)
			end)
			if not ok then
				log_once("toggle", err)
				cx:toast("error", "Wingman Live failed", tostring(err))
			end
		end,
	})

	tern.chrome.widget(WIDGET, {
		name = "Wingman",
		description = "Working, waiting and queued wingman agents; click to toggle the live panel.",
		icon = "activity",
		render = function(pane: StatusPaneInfo?): WidgetView?
			local ok, view = pcall(widget_view, pane)
			return if ok then view else nil
		end,
	})

	tern.on("widget_action", function(ev: WidgetActionEvent, cx: WindowCx): boolean
		if ev.widget ~= WIDGET then
			return false
		end
		local pane = tonumber(ev.row)
		if ev.act == "focus" and pane then
			pcall(function()
				cx.layout:focus(pane)
			end)
		end
		return true
	end)

	tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
		local ok, err = try(function()
			local info = cx.session:pane(ev.pane)
			if info == nil then
				return
			end
			track(ev.pane, ev.new, info.title, true)
			if ev.new == "working" then
				finished[ev.pane] = nil
			end
			if panel_pane ~= nil then
				tool_dirty[ev.pane] = true
			end
			M.on_state_change()
		end)
		if not ok then
			log_once("agent_state", err)
		end
	end)

	tern.on("agent_finished", function(ev: AgentFinishedEvent, _cx: WindowCx)
		local ok, err = try(function()
			if ev.result == "closed" then
				return
			end
			finished[ev.pane] = ev.result
			if panel_pane ~= nil then
				tool_dirty[ev.pane] = true
				mark_git_dirty(ev.pane)
				schedule_render()
			end
			M.on_state_change()
		end)
		if not ok then
			log_once("agent_finished", err)
		end
	end)

	tern.on("pane_closed", function(ev: PaneEvent, _cx: WindowCx)
		local ok, err = try(function()
			if ev.pane == panel_pane then
				forget_panel()
				return
			end
			if states[ev.pane] ~= nil then
				forget_agent(ev.pane)
				M.on_state_change()
			end
		end)
		if not ok then
			log_once("pane_closed", err)
		end
	end)

	tern.on("focus", function(_ev: FocusEvent, _cx: WindowCx)
		if panel_pane ~= nil then
			local ok, err = try(schedule_render)
			if not ok then
				log_once("focus", err)
			end
		end
	end)

	tern.on("canvas_action", on_canvas_action)

	-- A drag or throw let the panel go: keep where the user put it for the next open.
	tern.on("float_moved", function(ev: FloatMovedEvent, _cx: WindowCx)
		if ev.pane ~= panel_pane then
			return
		end
		local ok, err = try(function()
			placement = if ev.docked ~= nil then "right" else "float"
			local c: string? = ev.corner
			if c == "tl" or c == "tr" or c == "bl" or c == "br" then
				corner = c
			end
			save_prefs()
			schedule_render()
		end)
		if not ok then
			log_once("float_moved", err)
		end
	end)

	tern.on("budget", function(ev: BudgetEvent, _cx: WindowCx)
		if ev.state == "paused" then
			local ok, err = try(function()
				trip(string.format("Tern paused hook %s past %s ms", ev.hook, tostring(ev.ms)), ev.paused_ms)
			end)
			if not ok then
				log_once("budget", err)
			end
		end
	end)

	tern.on("unload", function()
		cancel_timers()
	end)

	tern.on("window_start", function(cx: WindowCx)
		local ok, err = try(function()
			seed(cx)
		end)
		if not ok then
			log_once("seed", err)
		end
	end)
	tern.timer(0, function(cx: WindowCx?)
		if cx ~= nil then
			local ok, err = try(function()
				seed(cx)
			end)
			if not ok then
				log_once("seed", err)
			end
		end
	end)
end

return M
