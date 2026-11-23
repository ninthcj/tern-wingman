--!strict
-- Wingman Live Panel view: pure functions from a snapshot of the radar's data to plain node tables styled by the
-- `radar` sheet. Nothing here reads or writes controller state: every input arrives in a `Frame`, every output is a
-- node (plus the identity colors a section newly handed out, which the controller records before the next section).
-- The `tern.ui.*` builders are native calls: measured ~6x the cost and ~190 KB of garbage per 268-node build,
-- against ~0 for the same tables built here.

local ROLE = "wingman.radar"

-- The panel's sheet: a stage lit by the agents' mood, cards on a rail, a compact file tree, a feed. Colors come
-- from Tern's tokens through relative colors (Tern drops a gradient stop whose `var()` holds `light-dark()`);
-- motion is CSS only, so it costs no Lua and Reduce Motion stops it. Reinstalled on every load: Tern drops
-- plugin sheets on reload but keeps the canvas.
local CSS = [==[
.wr { display: flex; flex-direction: column; gap: 10px; min-width: 0; font: 400 12px/16px var(--sans); color: var(--t1); }
.wr-eyebrow { font: 600 9.5px/12px var(--mono); letter-spacing: 0.14em; text-transform: uppercase; color: var(--t3); white-space: nowrap; }
.wr-meta { margin-left: auto; font: 500 10.5px/14px var(--mono); font-variant-numeric: tabular-nums; color: var(--t3); white-space: nowrap; }
.wr-time { flex: none; font: 500 10.5px/14px var(--mono); font-variant-numeric: tabular-nums; color: var(--t3); white-space: nowrap; }
.wr-empty, .wr-more { padding: 2px 4px; font: 400 11.5px/16px var(--sans); color: var(--t3); }
.wr-warn { padding: 2px 4px; font: 500 11px/16px var(--sans); color: var(--warn); }
.wr-sec { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.wr-sh { display: flex; align-items: center; gap: 8px; padding: 0 2px; }

/* stage */
.wr-stage { position: relative; display: flex; flex-direction: column; gap: 8px; padding: 8px 8px 9px; border-radius: 12px;
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
.wr-cards { display: flex; flex-direction: column; gap: 6px; }
.wr-card { display: flex; flex-direction: column; gap: 5px; min-width: 0; padding: 7px 8px; border-radius: 10px;
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
.wr-dir { padding: 2px 4px 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font: 500 10.5px/16px var(--mono); color: var(--t3); }
.wr-files { position: relative; display: flex; flex-direction: column; margin-left: 6px; padding-left: 8px; }
.wr-files::before { content: ""; position: absolute; left: 0; top: 2px; bottom: 6px; width: 1px; background-color: var(--l2); }
.wr-file { display: flex; align-items: center; gap: 6px; min-width: 0; min-height: 20px; padding: 0 4px; border-radius: 5px; cursor: pointer; }
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
.wr-dock { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; min-width: 0; }
.wr-dock .wr-btn.sf-el { display: flex; align-items: center; gap: 5px; min-height: 0; padding: 3px 9px; border: 0; border-radius: 6px;
	background-color: transparent; box-shadow: 0 0 0 1px var(--l2); font: 500 11.5px/16px var(--sans); color: var(--t2); cursor: pointer; }
.wr-dock .wr-btn.sf-el:hover { background-color: var(--l1); color: var(--t1); }
.wr-dock .wr-btn.wr-quiet.sf-el { padding: 3px 7px; box-shadow: none; font-size: 11px; color: var(--t3); }
.wr-dock .wr-btn.wr-quiet.sf-el:hover { background-color: var(--l1); color: var(--t1); }
.wr-dock .wr-btn.wr-quiet.sf-el[data-on] { color: var(--accent); }
.wr-dock .wr-btn.wr-quiet.sf-el[data-on]:hover { color: var(--accent); }
.wr-lite { margin-left: auto; padding: 0 6px; border-radius: 4px; font: 600 10px/15px var(--mono); color: var(--warn);
	background-color: rgb(from var(--warn) r g b / 14%); }
.wr-health { margin-left: auto; flex: none; width: 7px; height: 7px; border-radius: 4px; background-color: var(--ok); opacity: 0.6; }
.wr-lite + .wr-health { margin-left: 0; }
.wr-health[data-mode='lite'] { background-color: var(--warn); opacity: 1; }

@media (prefers-reduced-motion: reduce) {
	.wr-stage::before, .wr-dot, .wr-b { animation: none !important; }
}
]==]

export type Scope = "tab" | "all"
export type Placement = "right" | "float"

export type Row = {
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

export type ToolRec = {
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

export type GitEntry = { path: string, code: string, ins: number, del: number, conflict: boolean }

export type Repo = {
	root: string,
	branch: string?,
	files: { GitEntry }?,
	err: string?,
	inflight: boolean,
	dirty: boolean,
	next_at: number,
}

--- Tool records: `ids` in call order (oldest first), `by_id` their records, `cleared` the reads the user hid.
export type Tools = { ids: { string }, by_id: { [string]: ToolRec }, cleared: { [string]: boolean } }

--- When each agent entered its state: `since` is tern.now() time, `since_wall` os.time(); `exact` is false for a
--- state first seen mid-flight.
export type Clocks = { exact: { [number]: boolean }, since: { [number]: number }, since_wall: { [number]: number } }

--- Identity colors handed out so far (`of`) and the one the next agent gets (`next % 6`).
export type Hues = { of: { [number]: number }, next: number }

--- A color a section assigned to an agent for the first time; the controller records it, in order.
export type HueGrant = { pane: number, hue: number }

export type Section = { node: Node, grants: { HueGrant } }

export type Frame = {
	rows: { Row },
	by_pane: { [number]: Row },
	roots: { string },
	repos: { [string]: Repo },
	tools: Tools,
	clocks: Clocks,
	titles: { [number]: string },
	hues: Hues,
	scope: Scope,
	placement: Placement,
	panel_sx: number,
	panel_sy: number,
	mode: string, -- "rich" | "lite"
	lite_until: number,
	lite_reason: string,
	now_ms: number,
	home: string?,
}

--- What the dock's health dot reports of the last render.
export type DockInfo = {
	mode: string,
	lite_reason: string,
	last_lua: number,
	last_wall: number,
	last_nodes: number,
	last_bytes: number,
	renders: number,
	last_phases: string,
	budget_ms: number,
	safe_ms: number,
	subagents_enabled: boolean,
	subagent_limit: number,
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

local HOT_MS = 30000 -- a file touched this recently glows

local function loom_cap(f: Frame): number
	return math.clamp(math.floor(f.panel_sx * 100), 14, 36)
end

local function viewport_lines(f: Frame): number
	return math.clamp(math.floor(24 * f.panel_sy), 12, 28)
end

local function feed_cap(f: Frame): number
	return math.clamp(math.floor(viewport_lines(f) / 3), 4, 10)
end
local SEARCH: { [string]: boolean } = { grep = true, find = true, glob = true, ast_grep = true, search = true, lsp = true,
	grep_search = true, find_by_name = true, codebase_search = true }

local PLACE_TIP: { [string]: string } = {
	pip = "Floating over its owner",
	tab = "In a different tab than its owner",
	parked = "Parked: running but not on screen",
}

------------------------------------------------------------------------------------------------------------------------
-- Text helpers

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

local function basename(path: string): string
	return string.match(path, "([^/\\]+)[/\\]*$") or path
end

local function norm_sep(p: string): string
	return (string.gsub(p, "\\", "/"))
end

local function display_path(abs: string, roots: { string }, home: string?): string
	local norm_abs = norm_sep(abs)
	for _, root in roots do
		local nr = norm_sep(root)
		if string.sub(norm_abs, 1, #nr + 1) == nr .. "/" then
			local rel = string.sub(norm_abs, #nr + 2)
			return if #roots > 1 then basename(nr) .. "/" .. rel else rel
		end
	end
	if home then
		local nh = norm_sep(home)
		if string.sub(norm_abs, 1, #nh + 1) == nh .. "/" then
			return "~" .. string.sub(norm_abs, #nh + 1)
		end
	end
	return norm_abs
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

-- Takes `n`'s node count off the budget when it fits.
local function fits(b: Budget, n: Node): boolean
	local c = count_nodes(n)
	if c > b.left then
		return false
	end
	b.left -= c
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- Node builders

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

-- The identity color of an agent (first-seen order); colors it hands out are collected in `grants`.
local function palette(base: Hues): ((pane: number) -> string, { HueGrant })
	local grants: { HueGrant } = {}
	local added: { [number]: number } = {}
	local function hue(pane: number): string
		local h = base.of[pane] or added[pane]
		if h == nil then
			h = (base.next + #grants) % 6
			added[pane] = h
			table.insert(grants, { pane = pane, hue = h })
		end
		return tostring(h)
	end
	return hue, grants
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

local function tool_label(t: ToolRec, roots: { string }, home: string?): string
	return if t.path then clip_start(display_path(t.path, roots, home), 72) else clip(t.target, 72)
end

-- Each pane's tool records in call order.
local function tools_by_pane(tools: Tools, by_pane: { [number]: Row }): { [number]: { ToolRec } }
	local out: { [number]: { ToolRec } } = {}
	for _, id in tools.ids do
		local t = tools.by_id[id]
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

------------------------------------------------------------------------------------------------------------------------
-- Agents

-- One agent: its head row (focus target, chips, time, actions) and, while active, its current tool and strip.
local function agent_parts(f: Frame, hue: (number) -> string, r: Row, ts: { ToolRec }?): { Node }
	local pane = tostring(r.pane)
	local now_ms = f.now_ms
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
	local clocks = f.clocks
	local when = if active
		then (if clocks.exact[r.pane] then "" else "≥") .. fmt_dur(now_ms - (clocks.since[r.pane] or now_ms))
		else (if clocks.exact[r.pane] then "" else "≤") .. os.date("%H:%M", clocks.since_wall[r.pane] or os.time())
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
			txt("span", "wr-tgt", tool_label(cur, f.roots, f.home)),
			txt("span", "wr-time", tool_dur(cur, now_ms)),
		}, { actions = { click = "focus=" .. pane }, title = cur.target }))
		local blocks: { Node } = {}
		local max_blocks = loom_cap(f)
		for i = math.max(1, #ts - max_blocks + 1), #ts do
			local t = ts[i]
			local a: { [string]: any } = { ["data-k"] = category(t) }
			if running(t) then
				a["data-run"] = true
			end
			local dur = tool_dur(t, now_ms)
			table.insert(blocks, el("i", "wr-b", nil, {
				attrs = a,
				title = t.name .. " " .. basename(tool_label(t, f.roots, f.home)) .. (if dur ~= "" then " · " .. dur else ""),
			}))
		end
		table.insert(parts, el("div", "wr-loom", blocks))
	end
	return parts
end

-- Each owner as a card with its wingmen on a rail (a wingman may own others in turn), then agents nobody owns.
local function topology(f: Frame, budget_left: number): Section
	local hue, grants = palette(f.hues)
	local budget: Budget = { left = budget_left }
	local rows, by_pane = f.rows, f.by_pane
	local by_tool = tools_by_pane(f.tools, by_pane)
	local kids: { Node } = {}
	local hidden = 0
	local placed: { [number]: boolean } = {}
	local chain: (r: Row) -> { Node }
	chain = function(r: Row): { Node }
		placed[r.pane] = true
		local parts = agent_parts(f, hue, r, by_tool[r.pane])
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
		table.insert(kids, txt("div", "wr-empty", if f.scope == "tab" then "No agents in this tab — switch to All above." else "No agents."))
	end
	if hidden > 0 then
		table.insert(kids, more_line(hidden))
	end
	local bound = 0
	for _, r in rows do
		if r.owner ~= nil then
			bound += 1
		end
	end
	local node = el("div", "wr-sec", { section_head("Agents", string.format("%d · %d bound", #rows, bound)), el("div", "wr-cards", kids) })
	return { node = node, grants = grants }
end

------------------------------------------------------------------------------------------------------------------------
-- Living files

-- Diff bar width bucket: log4 of the line count, 1–6.
local function bucket(n: number): string?
	if n <= 0 then
		return nil
	end
	return tostring(math.min(6, 1 + math.floor(math.log(n) / math.log(4))))
end

local function file_row(hue: (number) -> string, f: FileRow, name: string, now_ms: number): Node
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

local function scope_path(path: string): string
	local windows = string.match(path, "^%a:[/\\]") ~= nil or string.sub(path, 1, 2) == "\\\\"
	if windows then
		path = string.lower((string.gsub(path, "\\", "/")))
	end
	local drive = if windows then string.match(path, "^%a:") else nil
	local prefix = if drive then drive .. "/" elseif windows then "//" else "/"
	local parts: { string } = {}
	for part in string.gmatch(if drive then string.sub(path, 3) else path, "[^/]+") do
		if part == ".." then
			parts[#parts] = nil
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return prefix .. table.concat(parts, "/")
end

local function living_files(f: Frame, budget_left: number): Section
	local hue, grants = palette(f.hues)
	local budget: Budget = { left = budget_left }
	local roots, now_ms, tools = f.roots, f.now_ms, f.tools
	local prefixes: { string } = {}
	local seen: { [string]: boolean } = {}
	local function include_dir(dir: string)
		if dir ~= "" and not seen[dir] then
			seen[dir] = true
			local path = scope_path(dir)
			table.insert(prefixes, if string.sub(path, -1) == "/" then path else path .. "/")
		end
	end
	for _, root in roots do
		include_dir(root)
	end
	for _, row in f.rows do
		include_dir(row.cwd)
	end
	local function in_scope(path: string): boolean
		local key = scope_path(path)
		for _, prefix in prefixes do
			if string.sub(key, 1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	local files: { [string]: FileRow } = {}
	local list: { FileRow } = {}
	local function entry(abs: string): FileRow
		local row = files[abs]
		if row == nil then
			row = { abs = abs, code = nil, ins = 0, del = 0, conflict = false, edits = 0, reads = 0, last = -math.huge, panes = {} }
			files[abs] = row
			table.insert(list, row)
		end
		return row
	end
	local heads: { Node } = {}
	for _, root in roots do
		local repo = f.repos[root]
		if repo then
			local ins, del = 0, 0
			local changed = repo.files
			if changed then
				for _, g in changed do
					local row = entry(root .. "/" .. g.path)
					row.code, row.ins, row.del, row.conflict = g.code, g.ins, g.del, g.conflict
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
	for _, id in tools.ids do
		local t = tools.by_id[id]
		if t.path ~= nil and f.by_pane[t.pane] ~= nil
			and (t.kind == "edit" or (t.kind == "read" and not tools.cleared[id] and in_scope(t.path))) then
			local row = entry(t.path)
			if t.kind == "edit" then
				row.edits += 1
			else
				row.reads += 1
			end
			row.panes[t.pane] = true
			row.last = math.max(row.last, t.seen)
		end
	end
	-- Which files show: conflicts, then touched changes, then changes, then reads, newest first. How they show:
	-- by directory, then name, so rows only move when one comes or goes.
	local function rank(row: FileRow): number
		if row.conflict then
			return 3
		elseif row.edits > 0 or (row.code ~= nil and row.reads > 0) then
			return 2
		elseif row.code ~= nil then
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
	-- Dynamic vertical line budget: derived from the panel's actual vertical share, active agents, and feed rows.
	local max_feed = feed_cap(f)
	local agent_lines = 0
	for _, r in f.rows do
		agent_lines += if r.state == "idle" and r.fault == nil and r.queued == 0 then 1 else 3
	end
	local feed_lines = 0
	for _, id in tools.ids do
		local t = tools.by_id[id]
		if t and f.by_pane[t.pane] ~= nil then
			feed_lines += 1
			if feed_lines >= max_feed then
				break
			end
		end
	end
	local vp = viewport_lines(f)
	local file_line_cap = math.clamp(vp - agent_lines - feed_lines, 6, math.max(8, vp - 6))
	local has_changes = false
	for _, row in list do
		if row.code ~= nil or row.edits > 0 then
			has_changes = true
			break
		end
	end
	local read_cap = if has_changes then math.max(2, math.floor(file_line_cap * 0.5)) else file_line_cap

	type Shown = { dir: string, name: string, node: Node }
	local shown: { Shown } = {}
	local hidden = 0
	local dirs: { [string]: boolean } = {}
	local reads, lines = 0, 0
	for _, row in list do
		local read_only = row.code == nil and row.edits == 0
		if (read_only and reads >= read_cap) or lines >= file_line_cap then
			hidden += 1
			continue
		end
		local path = display_path(row.abs, roots, f.home)
		local parent, basename = string.match(path, "^(.*[/\\])([^/\\]+)$")
		local dir, name = parent or "", basename or path
		local cost = if dir == "" or dirs[dir] then 1 else 2
		if lines + cost > file_line_cap then
			hidden += 1
			continue
		end
		local n = file_row(hue, row, name, now_ms)
		if fits(budget, n) then
			table.insert(shown, { dir = dir, name = name, node = n })
			dirs[dir] = true
			lines += cost
			if read_only then
				reads += 1
			end
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
	return { node = el("div", "wr-sec", kids), grants = grants }
end

------------------------------------------------------------------------------------------------------------------------
-- Activity feed

local function activity(f: Frame, budget_left: number): Section
	local hue, grants = palette(f.hues)
	local budget: Budget = { left = budget_left }
	local tools, now_ms = f.tools, f.now_ms
	local list: { ToolRec } = {}
	for _, id in tools.ids do
		local t = tools.by_id[id]
		if f.by_pane[t.pane] ~= nil then
			table.insert(list, t)
		end
	end
	table.sort(list, function(x: ToolRec, y: ToolRec): boolean
		return if x.seen ~= y.seen then x.seen > y.seen else x.seq > y.seq
	end)
	local max_feed = feed_cap(f)
	local kids: { Node } = {}
	for _, t in list do
		if #kids >= max_feed then
			break
		end
		local a: { [string]: any }? = if running(t) then { ["data-run"] = true } elseif t.status == "lost" then { ["data-lost"] = true } else nil
		local n = el("div", "wr-act", {
			el("i", "wr-hue", nil, { attrs = { ["data-hue"] = hue(t.pane) } }),
			kind_badge(t),
			txt("span", "wr-tgt", tool_label(t, f.roots, f.home)),
			txt("span", "wr-time", tool_dur(t, now_ms)),
		}, {
			key = "t" .. t.seq,
			actions = { click = "focus=" .. t.pane },
			title = t.target .. "\nFocus " .. (f.titles[t.pane] or ("pane " .. t.pane)),
			attrs = a,
		})
		if not fits(budget, n) then
			break
		end
		table.insert(kids, n)
	end
	if f.mode == "lite" then
		local left = math.max(0, math.ceil((f.lite_until - now_ms) / 1000))
		table.insert(kids, 1, txt("div", "wr-warn", string.format("Sampling paused (%s) — resumes in %ds", f.lite_reason, left)))
	end
	if #list == 0 then
		table.insert(kids, txt("div", "wr-empty", "No tool calls yet."))
	end
	local node = el("div", "wr-sec", { section_head("Activity", if #list > 0 then "last " .. math.min(#list, max_feed) else nil), el("div", nil, kids) })
	return { node = node, grants = grants }
end

------------------------------------------------------------------------------------------------------------------------
-- Stage, page and dock

local function stage(f: Frame): Node
	local scope = f.scope
	local working, waiting, queued, faults = 0, 0, 0, 0
	for _, r in f.rows do
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
	local floating = f.placement == "float"
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

--- The canvas view: the stage over the three sections (already built).
local function page(f: Frame, topo: Node, files: Node, feed: Node): Node
	return { k = "col", p = { role = ROLE }, c = { el("div", "wr", { stage(f), topo, files, feed }) } }
end

local function dock_node(info: DockInfo): Node
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
	local subs_tip = if info.subagents_enabled
		then "Subagent panes on: each running subagent gets its own pane. Click to turn off"
		else "Subagent panes off. Click to show each running subagent in its own pane"
	local label = if info.subagents_enabled then "Popouts" else "Popouts: Off"
	table.insert(kids, el("button", "wr-btn wr-quiet", { txt("span", nil, label) }, {
		actions = { click = "subagent_toggle" },
		title = subs_tip,
		attrs = {
			["aria-label"] = subs_tip,
			["aria-pressed"] = if info.subagents_enabled then "true" else "false",
			["data-on"] = if info.subagents_enabled then true else nil,
		},
	}))
	if info.subagents_enabled then
		local unlimited = info.subagent_limit == 0
		local limit = if unlimited then "∞" else "≤" .. info.subagent_limit
		local limit_tip = if unlimited then "Unlimited subagent panes. Click to change"
			else string.format("At most %d subagent panes in this window (pinned ones count). Click to change", info.subagent_limit)
		table.insert(kids, el("button", "wr-btn wr-quiet", { txt("span", nil, limit) }, {
			actions = { click = "subagent_limit" },
			title = limit_tip,
			attrs = { ["aria-label"] = limit_tip },
		}))
	end
	if info.mode == "lite" then
		table.insert(kids, txt("span", "wr-lite", "lite", { title = "Transcript sampling paused: " .. info.lite_reason }))
	end
	table.insert(kids, el("span", "wr-health", nil, {
		attrs = { ["data-mode"] = info.mode },
		title = string.format(
			"%s · %.1f ms Lua / %.1f ms wall · %d nodes · %d KB\nRender #%d, ms per phase: %s\nBudget: %d ms Lua a call (radar keeps under %d)",
			info.mode,
			info.last_lua,
			info.last_wall,
			info.last_nodes,
			math.ceil(info.last_bytes / 1024),
			info.renders,
			info.last_phases,
			info.budget_ms,
			info.safe_ms
		),
	}))
	return { k = "col", p = { role = ROLE .. ".dock" }, c = { el("div", "wr-dock", kids) } }
end

export type WidgetRow = { pane: number, state: string, fault: boolean, queued: number, title: string? }

local function widget_view(rows: { WidgetRow }, working: number, waiting: number, queued: number, command: string): WidgetView
	local card: { WidgetCardRow } = {}
	for _, row in rows do
		local state, q = row.state, row.queued
		local label = if row.fault then "fault" elseif state == "waiting_input" then "waiting" else state
		table.insert(card, {
			id = tostring(row.pane),
			label = clip(label .. (if q > 0 then " · Q:" .. q else ""), 40),
			text = clip(row.title or string.format("#%04d", row.pane % 10000), 120),
			tone = if row.fault then "error" elseif state == "waiting_input" then "warn" else nil,
			actions = { { id = "focus", label = "Focus" } },
		})
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
		command = command,
		card = if #card > 0 then card else nil,
	}
end

return {
	CSS = CSS,
	clip = clip,
	fmt_dur = fmt_dur,
	count_nodes = count_nodes,
	topology = topology,
	living_files = living_files,
	activity = activity,
	page = page,
	dock_node = dock_node,
	widget_view = widget_view,
}
