--!strict
-- Subagent pane view: pure functions from one `subagents.Record` to the two nodes of a physical pane, the body and
-- its dock. Nothing here reads controller state or calls a `tern.*` builder; the `sv` sheet below is installed by
-- the controller next to the radar's. Colors come from Tern's tokens, motion is CSS only, so Reduce Motion stops it
-- and a pane costs no Lua between renders.

local subagents = require("./subagents")
local radar_view = require("./radar_view")

local ROLE = "wingman.subagent"
local TEXT_CAP = 4000
local BADGE_CAP = 6

local CSS = [==[
.sv { position: relative; display: flex; flex-direction: column; gap: 8px; min-width: 0; min-height: 0; padding: 9px 10px 10px;
	overflow: hidden; font: 400 12px/16px var(--sans); color: var(--t1); background-color: var(--code-bg);
	box-shadow: inset 2px 0 0 var(--sv-hue), inset 0 1px 0 var(--glass-hi); --sv-hue: var(--t4); }
.sv[data-hue='0'] { --sv-hue: oklch(70% 0.13 255); }
.sv[data-hue='1'] { --sv-hue: oklch(72% 0.14 155); }
.sv[data-hue='2'] { --sv-hue: oklch(76% 0.14 75); }
.sv[data-hue='3'] { --sv-hue: oklch(68% 0.15 330); }
.sv[data-hue='4'] { --sv-hue: oklch(72% 0.12 200); }
.sv[data-hue='5'] { --sv-hue: oklch(68% 0.15 25); }
.sv::before { content: ""; position: absolute; left: 0; right: 0; top: 0; height: 2px; pointer-events: none; opacity: 0;
	background-image: linear-gradient(90deg, rgb(from var(--accent) r g b / 0%), var(--accent), rgb(from var(--accent) r g b / 0%)); }
.sv[data-s='running']::before { opacity: 1; animation: sv-sweep 1.8s ease-in-out infinite; }
@keyframes sv-sweep { 0% { transform: translateX(-100%); } 100% { transform: translateX(100%); } }
.sv-head { display: flex; align-items: flex-start; gap: 7px; min-width: 0; }
.sv-title { flex: 1; min-width: 0; overflow-wrap: anywhere; font: 600 12.5px/16px var(--sans); color: var(--t1); }
.sv-time { flex: none; font: 500 10.5px/16px var(--mono); font-variant-numeric: tabular-nums; color: var(--t3); white-space: nowrap; }
.sv-dot { flex: none; width: 8px; height: 8px; margin-top: 4px; border-radius: 4px; background-color: var(--t4); }
.sv-dot[data-s='running'] { background-color: var(--accent); animation: sv-pulse 1.6s ease-out infinite; }
.sv-dot[data-s='done'] { background-color: var(--ok); }
.sv-dot[data-s='error'] { background-color: var(--bad); box-shadow: 0 0 0 3px rgb(from var(--bad) r g b / 22%); }
@keyframes sv-pulse { 0% { box-shadow: 0 0 0 0 rgb(from var(--accent) r g b / 55%); } 100% { box-shadow: 0 0 0 6px rgb(from var(--accent) r g b / 0%); } }
.sv-meta { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; min-width: 0; }
.sv-chip { max-width: 100%; padding: 0 5px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; border-radius: 4px;
	font: 600 10px/15px var(--mono); color: var(--t2); background-color: var(--l1); }
.sv-chip[data-t='running'] { color: var(--accent); background-color: rgb(from var(--accent) r g b / 14%); }
.sv-chip[data-t='done'] { color: var(--ok); background-color: rgb(from var(--ok) r g b / 14%); }
.sv-chip[data-t='error'] { color: var(--bad); background-color: rgb(from var(--bad) r g b / 14%); }
.sv-text { flex: 1; min-height: 0; margin: 0; padding: 7px 8px; overflow-x: hidden; overflow-y: auto; white-space: pre-wrap;
	overflow-wrap: anywhere; border-radius: 8px; font: 400 11px/16px var(--mono); color: var(--t2);
	background-color: var(--well); box-shadow: 0 0 0 1px var(--well-line); }
.sv-text[data-empty] { color: var(--t4); }

.sv-dock { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; min-width: 0; padding: 4px 6px;
	background-color: var(--code-bg); box-shadow: inset 2px 0 0 var(--sv-hue); --sv-hue: var(--t4); }
.sv-dock[data-hue='0'] { --sv-hue: oklch(70% 0.13 255); }
.sv-dock[data-hue='1'] { --sv-hue: oklch(72% 0.14 155); }
.sv-dock[data-hue='2'] { --sv-hue: oklch(76% 0.14 75); }
.sv-dock[data-hue='3'] { --sv-hue: oklch(68% 0.15 330); }
.sv-dock[data-hue='4'] { --sv-hue: oklch(72% 0.12 200); }
.sv-dock[data-hue='5'] { --sv-hue: oklch(68% 0.15 25); }
.sv-dock .sv-btn.sf-el { display: flex; flex: none; align-items: center; gap: 4px; min-height: 0; padding: 2px 7px; border: 0; border-radius: 5px;
	background-color: transparent; box-shadow: none; font: 500 11px/16px var(--sans); color: var(--t2); cursor: pointer; }
.sv-dock .sv-btn.sf-el:hover { background-color: var(--l2); color: var(--t1); }
.sv-dock .sv-btn.sf-el[data-on] { background-color: var(--l1); color: var(--t1); box-shadow: 0 0 0 1px var(--l2); }
.sv-dock .sv-parent.sf-el { flex: 1 1 0; min-width: 0; }
.sv-dock .sv-parent span { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.sv-hue { flex: none; width: 6px; height: 6px; border-radius: 3px; background-color: var(--sv-hue); }

@media (prefers-reduced-motion: reduce) {
	.sv::before, .sv-dot { animation: none !important; }
}
]==]

local LABEL: { [string]: string } = { running = "Running", done = "Done", error = "Failed" }

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

local function button(class: string, act: string, tip: string, kids: { Node }, extra: { [string]: any }?): Node
	local attrs: { [string]: any } = { ["aria-label"] = tip }
	if extra then
		for k, v in extra do
			attrs[k] = v
		end
	end
	return el("button", class, kids, { actions = { click = act }, title = tip, attrs = attrs })
end

local function hue_of(hue: number): string
	return tostring(math.floor(hue) % 6)
end

local function elapsed_ms(r: subagents.Record, running: boolean, now: number): number
	if running then
		return math.max(0, now - r.started_ms)
	end
	return r.took or math.max(0, (r.finished_ms or now) - r.started_ms)
end

--- The pane body and its dock for one subagent. `overflow` is how many other subagents wait for a pane.
local function render(record: subagents.Record, pinned: boolean, overflow: number, now: number): (Node, Node)
	local phase = record.status
	local running = phase == "running"
	local title = if record.title ~= "" then record.title else "Subagent"
	local parent = if record.parent_title ~= "" then record.parent_title else "Parent"
	local status = LABEL[phase]
	local hue = hue_of(record.parent_hue)
	local time = radar_view.fmt_dur(elapsed_ms(record, running, now))

	local meta: { Node } = { txt("span", "sv-chip", status, { attrs = { ["data-t"] = phase } }) }
	for i, badge in record.badges do
		if i > BADGE_CAP then
			break
		end
		table.insert(meta, txt("span", "sv-chip", radar_view.clip(badge, 24), { title = badge }))
	end

	local empty = record.text == ""
	local body = if empty then (if running then "Waiting for output…" else "No output.") else radar_view.clip(record.text, TEXT_CAP)

	local view: Node = {
		k = "col",
		p = { role = ROLE },
		c = {
			el("div", "sv", {
				el("div", "sv-head", {
					el("span", "sv-dot", nil, { attrs = { ["data-s"] = phase, ["aria-hidden"] = "true" } }),
					txt("span", "sv-title", title, { title = title }),
					txt("span", "sv-time", time, { title = if running then "Running for" else "Took" }),
				}),
				el("div", "sv-meta", meta),
				txt("pre", "sv-text", body, { attrs = { ["data-empty"] = if empty then true else nil, tabindex = "0", ["aria-label"] = "Subagent output" } }),
			}, {
				attrs = {
					["data-s"] = phase,
					["data-hue"] = hue,
					role = "region",
					["aria-label"] = string.format("Subagent %s, %s, %s", title, string.lower(status), time),
				},
			}),
		},
	}

	local controls: { Node } = {
		button("sv-btn sv-parent", "parent", "Focus the parent agent: " .. parent, {
			el("span", "sv-hue", nil, { attrs = { ["aria-hidden"] = "true" } }),
			txt("span", nil, "Parent · " .. parent),
		}),
		button(
			"sv-btn",
			"pin",
			if pinned then "Unpin: let this pane be replaced when others need room" else "Pin: keep this pane open",
			{ txt("span", nil, if pinned then "Unpin" else "Pin") },
			{ ["aria-pressed"] = if pinned then "true" else "false", ["data-on"] = if pinned then true else nil }
		),
		button("sv-btn", "close", "Close this pane", { { k = "icon", p = { name = "x" } } }),
	}
	if overflow > 0 then
		local tip = string.format("%d more subagent%s waiting for a pane: show the next", overflow, if overflow == 1 then "" else "s")
		table.insert(controls, button("sv-btn", "more", tip, { txt("span", nil, "+" .. overflow .. " more") }))
	end

	local dock: Node = {
		k = "col",
		p = { role = ROLE .. ".dock" },
		c = { el("div", "sv-dock", controls, { attrs = { ["data-hue"] = hue, role = "toolbar", ["aria-label"] = "Subagent pane controls" } }) },
	}
	return view, dock
end

return {
	CSS = CSS,
	render = render,
}
