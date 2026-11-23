--!nonstrict
-- Pure fixture for the Agents section of radar_view.luau, run directly (`luau tests/workbench_view_fixture.luau`):
-- it loads the real view and asserts the bound count, the standalone PiP/Park/Queue Ask controls, queue previews
-- with every queue action, and the budget-aware shedding of previews.
local view = require("../radar_view")

local function check(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

local function expect(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

local function row(pane: number, over: any?): any
	local r = {
		pane = pane,
		state = "idle",
		title = "agent " .. pane,
		model = nil,
		cwd = "/work",
		tab = 1,
		floating = false,
		focused = false,
		owner = nil,
		workers = {},
		parked = false,
		place = nil,
		queued = 0,
		inbox = 0,
		fault = nil,
		failed = false,
		queue_items = {},
		can_pip = false,
	}
	for k, v in over or {} do
		r[k] = v
	end
	return r
end

local function items(n: number): any
	local out = {}
	for i = 1, n do
		table.insert(out, { id = 100 + i, position = i, preview = "prompt number " .. i })
	end
	return out
end

local function frame(rows: any): any
	local by_pane = {}
	for _, r in rows do
		by_pane[r.pane] = r
	end
	return {
		rows = rows,
		by_pane = by_pane,
		roots = {},
		repos = {},
		tools = { ids = {}, by_id = {}, cleared = {} },
		clocks = { exact = {}, since = {}, since_wall = {} },
		titles = {},
		hues = { of = {}, next = 0 },
		scope = "all",
		placement = "right",
		panel_sx = 0.3,
		panel_sy = 1,
		mode = "rich",
		lite_until = 0,
		lite_reason = "",
		now_ms = 0,
		home = nil,
	}
end

-- Every click action in a node tree, in document order.
local function actions(node: any, out: any?): { string }
	local list = out or {}
	local p = node.p
	if p and p.actions and p.actions.click then
		table.insert(list, p.actions.click)
	end
	for _, kid in node.c or {} do
		actions(kid, list)
	end
	return list
end

local function has(list: { string }, action: string): boolean
	return table.find(list, action) ~= nil
end

local function texts(node: any, out: any?): { string }
	local list = out or {}
	if node.p and node.p.text then
		table.insert(list, node.p.text)
	end
	for _, kid in node.c or {} do
		texts(kid, list)
	end
	return list
end

local function count_class(node: any, class: string): number
	local n = if node.p and node.p.class == class then 1 else 0
	for _, kid in node.c or {} do
		n += count_class(kid, class)
	end
	return n
end

local function section(rows: any, budget: number?): any
	return view.topology(frame(rows), budget or 10000).node
end

local function meta(node: any): string
	return texts(node.c[1])[2]
end

-- Bound count: shown only when something is bound.
do
	expect(meta(section({ row(1), row(2) })), "2", "no bound agents shows the plain count, never '0 bound'")
	expect(meta(section({ row(1, { workers = { 2 } }), row(2, { owner = 1 }) })), "2 · 1 bound", "bound count shown when positive")
	check(not string.find(table.concat(texts(section({ row(1) })), "|"), "0 bound", 1, true), "no 0 bound anywhere")
end

-- Standalone agents (no owner): PiP, Park and Queue Ask all available.
do
	local acts = actions(section({ row(7, { can_pip = true }) }))
	check(has(acts, "pip=7"), "standalone pip")
	check(has(acts, "park=7"), "standalone park")
	check(has(acts, "queue_ask=7"), "standalone queue ask")
	check(not has(acts, "unqueue=7"), "no unqueue without queued prompts")
end

-- PiP hidden on a sole leaf (can_pip false); park and queue ask remain.
do
	local acts = actions(section({ row(7, { can_pip = false }) }))
	check(not has(acts, "pip=7"), "pip hidden when it cannot float")
	check(has(acts, "park=7") and has(acts, "queue_ask=7"), "park and queue ask stay")
end

-- Placement states: floating docks, parked unparks (no park), exited offers neither pip, park nor queue ask.
do
	local floating = actions(section({ row(1, { floating = true, can_pip = true }) }))
	check(has(floating, "dock=1") and not has(floating, "pip=1") and has(floating, "park=1"), "floating pane docks")
	local parked = actions(section({ row(2, { parked = true, can_pip = true }) }))
	check(has(parked, "unpark=2") and not has(parked, "park=2") and not has(parked, "pip=2"), "parked pane unparks")
	check(has(parked, "queue_ask=2"), "parked agent still takes queued asks")
	local exited = actions(section({ row(3, { state = "exited", can_pip = true }) }))
	check(not has(exited, "pip=3") and not has(exited, "park=3") and not has(exited, "queue_ask=3"), "exited agent offers no live controls")
end

-- Owned wingman keeps the same controls.
do
	local acts = actions(section({ row(1, { workers = { 2 } }), row(2, { owner = 1, can_pip = true }) }))
	check(has(acts, "pip=2") and has(acts, "park=2") and has(acts, "queue_ask=2"), "owned wingman controls")
end

-- Queue rows and every queue action; Unqueue stays; position 1 has no queue_top.
do
	local node = section({ row(5, { queued = 3, queue_items = items(3) }) })
	local acts = actions(node)
	check(has(acts, "unqueue=5"), "unqueue kept")
	check(not has(acts, "queue_top=101"), "first item cannot move to top")
	for _, id in { 102, 103 } do
		check(has(acts, "queue_top=" .. id), "queue_top " .. id)
	end
	for _, id in { 101, 102, 103 } do
		check(has(acts, "queue_edit=" .. id), "queue_edit " .. id)
		check(has(acts, "queue_cancel=" .. id), "queue_cancel " .. id)
	end
	expect(count_class(node, "wr-q"), 3, "three preview rows")
	local all = table.concat(texts(node), "|")
	check(string.find(all, "prompt number 2", 1, true) ~= nil, "preview text shown")
	check(has(texts(node), "#102"), "queue ID, not slot position, is displayed")
	check(string.find(all, "Q3", 1, true) ~= nil, "queued chip kept")
end

-- Cap and overflow: panel_sy 1 allows 4 previews; the rest collapse into one note.
do
	local node = section({ row(5, { queued = 7, queue_items = items(7) }) })
	expect(count_class(node, "wr-q"), 4, "preview cap")
	check(has(texts(node), "… 3 more"), "overflow note counts hidden items")
	local acts = actions(node)
	check(not has(acts, "queue_edit=105"), "overflowed items have no controls")
	local f = frame({ row(5, { queued = 7, queue_items = items(7) }) })
	f.panel_sy = 0.1
	local short = view.topology(f, 10000).node
	expect(count_class(short, "wr-q"), 2, "short panel shows the minimum previews")
	check(has(texts(short), "… 5 more"), "short panel overflow note")
end

-- Budget: previews shed before the card is hidden; a card that cannot fit at all is counted as hidden.
do
	local function card_nodes(node: any): number
		return view.count_nodes(node.c[2].c[1])
	end
	local rows = { row(5, { queued = 3, queue_items = items(3) }) }
	local bare = card_nodes(section({ row(5, { queued = 3 }) }))
	local full = card_nodes(section(rows))
	check(full > bare, "previews cost nodes")
	local tight = view.topology(frame(rows), bare).node
	expect(count_class(tight, "wr-card"), 1, "card kept without previews when only previews overflow")
	expect(count_class(tight, "wr-q"), 0, "previews shed")
	local partial = view.topology(frame(rows), full - 1).node
	local shown = count_class(partial, "wr-q")
	check(shown > 0 and shown < 3, "partial budget shows fewer previews")
	check(has(texts(partial), "… 1 more"), "partial budget notes the unshown preview")
	local none = view.topology(frame(rows), 1).node
	expect(count_class(none, "wr-card"), 0, "card hidden when nothing fits")
	check(has(texts(none), "… 1 more"), "hidden card summarized")
end

-- Other sections still build from the same frame.
do
	local f = frame({ row(1, { queued = 2, queue_items = items(2) }) })
	check(view.living_files(f, 10000).node ~= nil, "living files")
	check(view.activity(f, 10000).node ~= nil, "activity")
end

print("workbench_view_fixture: ok")
