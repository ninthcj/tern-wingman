--!strict
-- Wingman subagent panes: which subagent tool calls deserve a pop-out pane, and when each opens, updates and closes.
-- Pure model: no tern globals and no controller; time, panes and eligibility come in as arguments, every native
-- effect goes out through a `Driver` the caller supplies. The caller owns error handling around driver calls, so
-- every transition updates the model *before* its driver call: a throwing call is never retried in a loop.
local tsp = require("./tsp")

-- A subagent call opens a pane only after running this long, so calls that finish at once never flash a pane.
local DEBOUNCE_MS = 1500
-- A finished, unpinned pane lingers this long before it closes.
local GRACE_MS = 20000
-- A running pane shows elapsed time in whole seconds, so it is repainted at most once per second.
local TIMER_STEP_MS = 1000
local FIRST_RATIO = 0.34 -- first pane: below its parent, this share of the parent
local SPLIT_RATIO = 0.5 -- later panes: split the predecessor in half
local MIN_PANE_SHARE = 0.16 -- of the tab; an unlimited row wraps down rather than shrink below this
local DEFAULT_LIMIT = 3
local MAX_LIMIT = 32
local LIMIT_CYCLE = { 3, 2, 4, 0, 1 } -- 0 = unlimited
local TITLE_BYTES = 96
local TEXT_BYTES = 1200
local BADGE_BYTES = 24
local MAX_BADGES = 4
local TASK_ROLE = "omp.tool.task"
local SUBAGENT_NAMES: { [string]: boolean } = {
	task = true,
	subagent = true,
	invoke_subagent = true,
	agent = true,
}
local BADGE_FIELDS = { "agent", "subagent_type", "model" }

export type Status = "running" | "done" | "error"

export type Config = {
	enabled: boolean,
	-- Panes open at once across the whole window, pinned ones included; 0 = unlimited.
	limit: number,
}

-- What a driver draws for one subagent call. Frozen; a new one replaces it whenever content changes.
export type Record = {
	id: string, -- "<parent pane>|<tool key>"
	parent_pane: number,
	parent_title: string,
	parent_hue: number,
	title: string,
	status: Status,
	badges: { string },
	text: string,
	started_ms: number,
	finished_ms: number?,
	took: number?,
}

-- The native side. `open` returns the new pane, or nil while the canvas is unavailable (retried on a later
-- reconcile); `previous` is the last pane opened for the same parent's formation (never another parent's), nil
-- for its first. `update` returns false for a transient failure (retried, never memoized); showing a different
-- record in an existing pane is how a waiting call reuses a slot. `overflow` counts calls that want a pane but
-- have none.
export type Driver = {
	open: (record: Record, previous: number?, unlimited: boolean, overflow: number) -> number?,
	update: (pane: number, record: Record, pinned: boolean, overflow: number) -> boolean,
	close: (pane: number) -> (),
	focus: (parent: number) -> (),
}

export type Sub = {
	config: () -> Config,
	toggle: () -> (),
	cycle_limit: () -> (),
	-- Feeds one transcript sample of `parent`. Returns the depth of its oldest running subagent call
	-- (#messages - message index + 1), or 0 when none runs, so the next sample can reach back to it.
	observe: (parent: number, title: string, hue: number, messages: { AgentMessage }, now: number) -> number,
	finish_parent: (parent: number, status: "done" | "error", now: number) -> (),
	-- The parent pane is gone: every slot formed for it closes (pins included), as does every slot showing one of
	-- its calls; a running call of another parent displaced that way waits for a slot again.
	parent_closed: (parent: number, driver: Driver) -> (),
	-- The user closed a pane: its call stays dismissed until its parent closes. False when the pane is not ours.
	pane_closed: (pane: number) -> boolean,
	-- "pin" toggles the pin, "close" dismisses, "parent" focuses the parent of the record shown, "more" shows the
	-- next waiting call in this unpinned pane, displacing what it shows. False if unhandled.
	action: (pane: number, act: string, now: number, driver: Driver) -> boolean,
	-- Applies due transitions through `driver`. `eligible[parent]` lets that parent's calls open *new* panes; open
	-- panes are never closed for losing eligibility. At a full window a waiting call reuses only a finished,
	-- unpinned slot; a running one is never displaced here. `should_yield` is asked before each native mutation:
	-- when it says stop, returns true (work deferred, call again). Unavailable native canvas and failed updates are
	-- not deferral: the next reconcile retries them.
	reconcile: (now: number, eligible: { [number]: boolean }, driver: Driver, should_yield: (() -> boolean)?) -> boolean,
	-- Earliest future grace deadline of a finished, unpinned pane, if any; one-shot.
	next_expiry: () -> number?,
}

type Phase = "pending" | "open" | "hidden" | "closed"

type Entry = {
	key: string,
	seq: number,
	parent: number,
	phase: Phase, -- pending: never shown; hidden: shown, then displaced while still running; closed: never (again)
	status: Status,
	title: string,
	parent_title: string,
	hue: number,
	badges: { string },
	text: string,
	reported_took: number?,
	started_ms: number,
	finished_ms: number?,
	first_seen: number,
	sample: number, -- last observe that listed it
	inferred: boolean, -- finished because the parent finished or the call vanished, not because the call said so
	lost: boolean,
	view: Record,
	rev: number,
	dirty: boolean,
	pane: number?,
	pinned: boolean,
	home: number, -- the parent whose formation holds the pane; kept when another parent's call takes the slot
	open_seq: number, -- the slot's place in opening order
	hidden_seq: number,
	dead: boolean,
	sent_rev: number,
	sent_pinned: boolean,
	sent_overflow: number,
	sent_step: number,
}

local EMPTY_VIEW: Record = table.freeze({
	id = "",
	parent_pane = 0,
	parent_title = "",
	parent_hue = 0,
	title = "",
	status = "done" :: Status,
	badges = table.freeze({} :: { string }),
	text = "",
	started_ms = 0,
})

-- Where a new pane goes: (target pane, direction, share of the target). The first sits below its parent; the next
-- splits its predecessor to the right, or, in an unlimited row whose halves would fall under the minimum share of
-- the tab, below it.
local function placement(parent: number, previous: number?, share: number?, unlimited: boolean): (number, "down" | "right", number)
	if previous == nil then
		return parent, "down", FIRST_RATIO
	end
	if unlimited and share ~= nil and share / 2 < MIN_PANE_SHARE then
		return previous, "down", SPLIT_RATIO
	end
	return previous, "right", SPLIT_RATIO
end

local function read_config(raw: any): Config
	local enabled = false
	local limit = DEFAULT_LIMIT
	if type(raw) == "table" then
		enabled = raw.enabled == true
		local candidate = raw.limit
		if type(candidate) == "number" and candidate >= 0 and candidate <= MAX_LIMIT then
			limit = math.floor(candidate)
		end
	end
	return { enabled = enabled, limit = limit }
end

local function next_limit(limit: number): number
	local index = table.find(LIMIT_CYCLE, limit)
	if index == nil then
		return LIMIT_CYCLE[1]
	end
	return LIMIT_CYCLE[index % #LIMIT_CYCLE + 1]
end

local function one_line(text: string): string
	local collapsed = string.gsub(text, "%s+", " ")
	return string.match(collapsed, "^%s*(.-)%s*$") or collapsed
end

local function clip(text: string, max_bytes: number): string
	if #text <= max_bytes then
		return text
	end
	return tsp.clip_utf8_bytes(text, max_bytes) .. "…"
end

local function status_of(raw: any): Status
	if type(raw) ~= "string" then
		return "done"
	end
	local status = string.lower(raw)
	if status == "running" or status == "pending" then
		return "running"
	elseif status == "error" or status == "failed" then
		return "error"
	end
	return "done"
end

-- The tool's name; an ACP card named "tool" carries its real name as the title.
local function tool_name(t: { [string]: any }): string
	local raw = t.name
	local name = if type(raw) == "string" and raw ~= "" then raw else "tool"
	if name == "tool" then
		local title = tsp.spans_to_text(t.title)
		if title ~= "" then
			name = title
		end
	end
	return name
end

local function is_subagent(t: { [string]: any }, name: string): boolean
	local role = t.role
	if type(role) ~= "string" and type(t.p) == "table" then
		role = t.p.role
	end
	if type(role) == "string" then
		local normalized = string.lower(role)
		if normalized == TASK_ROLE or SUBAGENT_NAMES[string.match(normalized, "[^%.:/]+$") or ""] then
			return true
		end
	end
	return SUBAGENT_NAMES[string.lower(name)] == true or SUBAGENT_NAMES[string.lower(tsp.spans_to_text(t.title))] == true
end

-- Calls without a key (inline cards) collapse by what identifies them from the first sight on; a target is left
-- out because a running card fills it in as it goes.
local function tool_key(parent: number, t: { [string]: any }, name: string): string
	local key = t.key
	if type(key) == "string" and key ~= "" then
		return string.format("%d|%s", parent, key)
	end
	local href = if type(t.href) == "string" then t.href else ""
	local intent = clip(tsp.spans_to_text(t.intent), TITLE_BYTES)
	return string.format("%d|~%s|%s|%s", parent, string.lower(name), href, intent)
end

-- Intent > target > title > name.
local function call_title(t: { [string]: any }, name: string): string
	local text = tsp.spans_to_text(t.intent)
	if text == "" then
		text = tsp.spans_to_text(t.target)
	end
	if text == "" then
		text = tsp.spans_to_text(t.title)
	end
	if text == "" then
		text = name
	end
	text = string.match(text, 'toolSummary="([^"]+)"') or text -- ACP run cards
	return clip(one_line(text), TITLE_BYTES)
end

local function add_badge(list: { string }, text: string)
	if #list >= MAX_BADGES then
		return
	end
	local badge = clip(one_line(text), BADGE_BYTES)
	if badge == "" or table.find(list, badge) ~= nil then
		return
	end
	table.insert(list, badge)
end

local function fill_badges(list: { string }, t: { [string]: any }, name: string)
	table.clear(list)
	if type(t.badges) == "table" then
		for _, badge in ipairs(t.badges) do
			if #list >= MAX_BADGES then
				break
			end
			local value = if type(badge) == "table" then badge.text or badge.label or badge else badge
			add_badge(list, tsp.spans_to_text(value))
		end
	end
	add_badge(list, name)
	local meta = t.metadata
	for _, field in BADGE_FIELDS do
		local value: any = if type(meta) == "table" then meta[field] else nil
		if value == nil then
			value = t[field]
		end
		if type(value) == "string" then
			add_badge(list, value)
		end
	end
end

local function same_list(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if b[index] ~= value then
			return false
		end
	end
	return true
end

local function build_view(e: Entry): Record
	local badges = e.badges
	if e.lost then
		local extended = table.clone(e.badges)
		table.insert(extended, "lost")
		badges = table.freeze(extended)
	end
	local took = e.reported_took
	if took == nil and e.finished_ms ~= nil then
		took = e.finished_ms - e.started_ms
	end
	return table.freeze({
		id = e.key,
		parent_pane = e.parent,
		parent_title = e.parent_title,
		parent_hue = e.hue,
		title = e.title,
		status = e.status,
		badges = badges,
		text = e.text,
		started_ms = e.started_ms,
		finished_ms = e.finished_ms,
		took = took,
	})
end

local function timer_step(e: Entry, now: number): number
	if e.status ~= "running" then
		return -1
	end
	return math.floor((now - e.started_ms) / TIMER_STEP_MS)
end

local function by_open_seq(a: Entry, b: Entry): boolean
	return a.open_seq < b.open_seq
end

local function by_hidden_seq(a: Entry, b: Entry): boolean
	return a.hidden_seq < b.hidden_seq
end

local function new(configRaw: any): Sub
	local cfg = read_config(configRaw)
	local order: { Entry } = {} -- creation order
	local by_parent: { [number]: { [string]: Entry } } = {}
	local by_pane: { [number]: Entry } = {}
	-- Keys the user closed, per parent: a bare marker that outlives the entry, so a gap in the transcript sample
	-- cannot bring a dismissed call back.
	local dismissed: { [number]: { [string]: boolean } } = {}
	local last_eligible: { [number]: boolean } = {}
	local clock = 0
	local sample_seq = 0
	local next_seq = 0
	local next_open_seq = 0
	local next_hidden_seq = 0
	local dead_count = 0
	local scratch_badges: { string } = {}
	local open_list: { Entry } = {}
	local ready_new: { Entry } = {}
	local ready_hidden: { Entry } = {}
	local yield_check: (() -> boolean)? = nil

	local function compact()
		if dead_count == 0 then
			return
		end
		local total = #order
		local kept = 0
		for index = 1, total do
			local e = order[index]
			if not e.dead then
				kept += 1
				order[kept] = e
			end
		end
		for index = total, kept + 1, -1 do
			order[index] = nil
		end
		dead_count = 0
	end

	-- Forget an entry that holds no pane.
	local function drop(e: Entry)
		if e.dead then
			return
		end
		e.dead = true
		dead_count += 1
		local siblings = by_parent[e.parent]
		if siblings ~= nil and siblings[e.key] == e then
			siblings[e.key] = nil
			if next(siblings) == nil then
				by_parent[e.parent] = nil
			end
		end
	end

	-- Detaches an entry from its pane in the model; the caller then tells the driver.
	local function release(e: Entry, phase: Phase): number?
		local pane = e.pane
		if pane ~= nil and by_pane[pane] == e then
			by_pane[pane] = nil
		end
		e.pane = nil
		e.phase = phase
		e.sent_rev = -1
		return pane
	end

	-- An entry losing its pane: still running, it waits for a slot again; otherwise it is done with panes.
	local function demote(e: Entry): number?
		local waiting = e.status == "running"
		local pane = release(e, if waiting then "hidden" else "closed")
		if waiting then
			next_hidden_seq += 1
			e.hidden_seq = next_hidden_seq
		end
		return pane
	end

	local function close_slot(e: Entry, driver: Driver, keep_running: boolean?)
		local pane = if keep_running then demote(e) else release(e, "closed")
		if pane ~= nil then
			driver.close(pane)
		end
	end

	local function dismiss(e: Entry)
		local keys = dismissed[e.parent]
		if keys == nil then
			keys = {}
			dismissed[e.parent] = keys
		end
		keys[e.key] = true
	end

	local function refresh(e: Entry)
		if e.dirty then
			e.dirty = false
			e.rev += 1
			e.view = build_view(e)
		end
	end

	local function finish(e: Entry, status: Status, now: number, inferred: boolean)
		e.status = status
		e.finished_ms = now
		e.inferred = inferred
		e.dirty = true
		if e.phase == "pending" or e.phase == "hidden" then
			e.phase = "closed"
		end
	end

	-- `home` and `seq` are inherited when the entry takes over another record's slot.
	local function attach(e: Entry, pane: number, now: number, overflow: number, home: number, seq: number?)
		if seq == nil then
			next_open_seq += 1
			seq = next_open_seq
		end
		e.phase = "open"
		e.pane = pane
		e.home = home
		e.open_seq = seq :: number
		e.pinned = false
		e.sent_rev = e.rev
		e.sent_pinned = false
		e.sent_overflow = overflow
		e.sent_step = timer_step(e, now)
		by_pane[pane] = e
	end

	local function ingest(
		mine: { [string]: Entry },
		parent: number,
		t: { [string]: any },
		name: string,
		status: Status,
		now: number,
		parent_title: string,
		hue: number
	)
		local key = tool_key(parent, t, name)
		local title = call_title(t, name)
		local text = clip(tsp.spans_to_text(t.text), TEXT_BYTES)
		local reported = t.took
		local took: number? = if type(reported) == "number" and reported > 0 then reported else nil
		fill_badges(scratch_badges, t, name)
		local e = mine[key]
		if e == nil then
			next_seq += 1
			local keys = dismissed[parent]
			local waits = status == "running" and not (keys ~= nil and keys[key] == true)
			local fresh: Entry = {
				key = key,
				seq = next_seq,
				parent = parent,
				phase = if waits then "pending" else "closed",
				status = status,
				title = title,
				parent_title = parent_title,
				hue = hue,
				badges = table.freeze(table.clone(scratch_badges)),
				text = text,
				reported_took = took,
				started_ms = now,
				finished_ms = if status == "running" then nil else now,
				first_seen = now,
				sample = sample_seq,
				inferred = false,
				lost = false,
				view = EMPTY_VIEW,
				rev = 0,
				dirty = false,
				pane = nil,
				pinned = false,
				home = parent,
				open_seq = 0,
				hidden_seq = 0,
				dead = false,
				sent_rev = -1,
				sent_pinned = false,
				sent_overflow = 0,
				sent_step = -1,
			}
			fresh.view = build_view(fresh)
			mine[key] = fresh
			table.insert(order, fresh)
			return
		end
		e.sample = sample_seq
		if e.title ~= title then
			e.title = title
			e.dirty = true
		end
		if e.text ~= text then
			e.text = text
			e.dirty = true
		end
		if e.reported_took ~= took then
			e.reported_took = took
			e.dirty = true
		end
		if not same_list(e.badges, scratch_badges) then
			e.badges = table.freeze(table.clone(scratch_badges))
			e.dirty = true
		end
		if e.status == "running" then
			if status ~= "running" then
				finish(e, status, now, false)
			end
		elseif e.inferred and status ~= "running" then
			e.inferred = false
			e.lost = false
			e.status = status
			e.dirty = true
		end
	end

	local function observe(parent: number, title: string, hue: number, messages: { AgentMessage }, now: number): number
		clock = math.max(clock, now)
		sample_seq += 1
		local parent_title = clip(one_line(title), TITLE_BYTES)
		local mine = by_parent[parent]
		if mine == nil then
			mine = {}
			by_parent[parent] = mine
		end
		local earliest: number? = nil
		for index, message in messages do
			for _, t in message.tools do
				if type(t) == "table" then
					local name = tool_name(t)
					if is_subagent(t, name) then
						local status = status_of(t.status)
						if status == "running" and earliest == nil then
							earliest = index
						end
						ingest(mine, parent, t, name, status :: Status, now, parent_title, hue)
					end
				end
			end
		end
		for _, e in mine do
			if e.sample ~= sample_seq and e.status == "running" then
				finish(e, "done", now, true)
				e.lost = true
			end
			if e.phase == "closed" and e.sample ~= sample_seq then
				drop(e) -- no longer in the transcript and holding no pane
			else
				if e.parent_title ~= parent_title or e.hue ~= hue then
					e.parent_title = parent_title
					e.hue = hue
					e.dirty = true
				end
				refresh(e)
			end
		end
		if next(mine) == nil then
			by_parent[parent] = nil
		end
		compact()
		if earliest == nil then
			return 0
		end
		return #messages - earliest + 1
	end

	local function finish_parent(parent: number, status: "done" | "error", now: number)
		clock = math.max(clock, now)
		local mine = by_parent[parent]
		if mine == nil then
			return
		end
		local outcome: Status = if status == "error" then "error" else "done"
		for _, e in mine do
			if e.status == "running" then
				finish(e, outcome, now, true)
				refresh(e)
			end
		end
	end

	local function parent_closed(parent: number, driver: Driver)
		dismissed[parent] = nil
		by_parent[parent] = nil
		local panes: { number } = {}
		for _, e in order do
			if e.dead then
				continue
			end
			if e.phase == "open" and (e.parent == parent or e.home == parent) then
				local pane = if e.parent == parent then release(e, "closed") else demote(e)
				if pane ~= nil then
					table.insert(panes, pane)
				end
			end
			if e.parent == parent then
				e.phase = "closed"
				drop(e)
			end
		end
		compact()
		for _, pane in panes do
			driver.close(pane)
		end
	end

	local function pane_closed(pane: number): boolean
		local e = by_pane[pane]
		if e == nil then
			return false
		end
		dismiss(e)
		release(e, "closed")
		return true
	end

	local function deferred(): boolean
		return yield_check ~= nil and yield_check()
	end

	-- Sorts the entries into open slots and the calls that want one: running, eligible, and (new ones) past the
	-- debounce.
	local function gather(now: number, eligible: { [number]: boolean })
		table.clear(open_list)
		table.clear(ready_new)
		table.clear(ready_hidden)
		for _, e in order do
			if e.dead then
				continue
			end
			if e.phase == "open" then
				table.insert(open_list, e)
			elseif e.phase ~= "closed" then
				if e.status ~= "running" then
					e.phase = "closed"
				elseif eligible[e.parent] == true then
					if e.phase == "hidden" then
						table.insert(ready_hidden, e)
					elseif now - e.first_seen >= DEBOUNCE_MS then
						table.insert(ready_new, e)
					end
				end
			end
		end
		table.sort(open_list, by_open_seq)
		table.sort(ready_hidden, by_hidden_seq)
	end

	-- The last pane opened for `parent`'s own formation, whatever its slot shows now.
	local function formation_tail(parent: number): number?
		local tail: Entry? = nil
		for _, e in order do
			if e.phase == "open" and e.home == parent and not e.dead and (tail == nil or e.open_seq > tail.open_seq) then
				tail = e
			end
		end
		return if tail ~= nil then tail.pane else nil
	end

	-- The unpinned slot whose call finished longest ago.
	local function finished_slot(): Entry?
		local best: Entry? = nil
		for _, e in order do
			if e.phase == "open" and not e.pinned and not e.dead and e.finished_ms ~= nil then
				if best == nil or (e.finished_ms :: number) < (best.finished_ms :: number) then
					best = e
				end
			end
		end
		return best
	end

	-- Unpinned panes are closed finished first (longest finished first), then from the last opened, so the
	-- earlier slots keep their place.
	local function pick_victim(): Entry?
		local oldest: Entry? = nil
		local last: Entry? = nil
		for _, e in open_list do
			if e.phase == "open" and not e.pinned then
				local finished = e.finished_ms
				if finished ~= nil and (oldest == nil or finished < (oldest.finished_ms :: number)) then
					oldest = e
				end
				last = e
			end
		end
		return oldest or last
	end

	local function action(pane: number, act: string, now: number, driver: Driver): boolean
		local e = by_pane[pane]
		if e == nil then
			return false
		end
		clock = math.max(clock, now)
		if act == "pin" then
			e.pinned = not e.pinned
			local expired = e.finished_ms ~= nil and now - e.finished_ms >= GRACE_MS
			if not e.pinned and (not cfg.enabled or expired) then
				close_slot(e, driver, not cfg.enabled)
				return true
			end
			if driver.update(pane, e.view, e.pinned, math.max(e.sent_overflow, 0)) then
				e.sent_pinned = e.pinned
				e.sent_rev = e.rev
				e.sent_step = timer_step(e, now)
			end
			return true
		elseif act == "close" then
			dismiss(e)
			close_slot(e, driver)
			return true
		elseif act == "parent" then
			driver.focus(e.parent)
			return true
		elseif act == "more" then
			if e.pinned then
				return false
			end
			gather(now, last_eligible)
			local waiting = ready_new[1] or ready_hidden[1]
			if waiting == nil then
				return false
			end
			local displaced = e.status == "running" and last_eligible[e.parent] == true
			local remaining = #ready_new + #ready_hidden - 1 + (if displaced then 1 else 0)
			local before = waiting.phase
			waiting.phase = "closed"
			if not driver.update(pane, waiting.view, false, remaining) then
				waiting.phase = before :: Phase
				return false
			end
			local home, seq = e.home, e.open_seq
			demote(e)
			attach(waiting, pane, now, remaining, home, seq)
			return true
		end
		return false
	end

	local function reconcile(now: number, eligible: { [number]: boolean }, driver: Driver, should_yield: (() -> boolean)?): boolean
		clock = math.max(clock, now)
		last_eligible = eligible
		compact()
		yield_check = should_yield
		gather(now, eligible)
		local capacity = if cfg.limit == 0 then math.huge else cfg.limit
		local unlimited = cfg.limit == 0
		local open_count = #open_list

		-- Close: finished panes past their grace, everything unpinned once disabled, then the excess over the limit.
		for _, e in open_list do
			local due = e.finished_ms ~= nil and now - (e.finished_ms :: number) >= GRACE_MS
			if not e.pinned and (not cfg.enabled or due) then
				if deferred() then
					return true
				end
				close_slot(e, driver, not cfg.enabled)
				open_count -= 1
			end
		end
		if cfg.enabled then
			local original_count = open_count
			while open_count > capacity do
				local victim = pick_victim()
				if victim == nil then
					break
				end
				if deferred() then
					return true
				end
				close_slot(victim, driver, true)
				open_count -= 1
			end
			if open_count ~= original_count then
				gather(now, eligible)
			end
		end

		-- Replace a finished unpinned slot before opening a new pane. Running panes are only rotated by More.
		local wanted = if cfg.enabled then #ready_new + #ready_hidden else 0
		local halted = false
		local rounds = if wanted > 0 then 2 else 0
		for round = 1, rounds do
			local waiting: { Entry } = if round == 1 then ready_new else ready_hidden
			for _, e in waiting do
				local slot = finished_slot()
				if slot == nil and open_count < capacity then
					if deferred() then
						return true
					end
					local before = e.phase
					e.phase = "closed"
					-- The new pane is the last unpinned slot; with more opens to come it shows no count.
					local shown = if open_count + 1 >= capacity then wanted - 1 else 0
					local pane = driver.open(e.view, formation_tail(e.parent), unlimited, shown)
					if pane == nil then
						e.phase = before :: Phase
						halted = true
						break
					end
					attach(e, pane, now, shown, e.parent, nil)
					wanted -= 1
					open_count += 1
				elseif slot ~= nil then
					if deferred() then
						return true
					end
					local pane = slot.pane :: number
					local before = e.phase
					e.phase = "closed"
					if not driver.update(pane, e.view, false, wanted - 1) then
						e.phase = before :: Phase
						halted = true
						break
					end
					local home, seq = slot.home, slot.open_seq
					release(slot, "closed")
					attach(e, pane, now, wanted - 1, home, seq)
					wanted -= 1
				else
					halted = true
					break
				end
			end
			if halted then
				break
			end
		end

		-- Repaint only what changed; the last unpinned slot carries the count of calls still waiting.
		table.clear(open_list)
		for _, e in order do
			if e.phase == "open" and not e.dead then
				table.insert(open_list, e)
			end
		end
		table.sort(open_list, by_open_seq)
		local last_unpinned: Entry? = nil
		for _, e in open_list do
			if not e.pinned then
				last_unpinned = e
			end
		end
		for _, e in open_list do
			local overflow = if e == last_unpinned then wanted else 0
			local step = timer_step(e, now)
			if e.sent_rev ~= e.rev or e.sent_pinned ~= e.pinned or e.sent_overflow ~= overflow or e.sent_step ~= step then
				if deferred() then
					return true
				end
				if driver.update(e.pane :: number, e.view, e.pinned, overflow) then
					e.sent_rev = e.rev
					e.sent_pinned = e.pinned
					e.sent_overflow = overflow
					e.sent_step = step
				end
			end
		end
		return false
	end

	local function next_expiry(): number?
		local soonest: number? = nil
		for _, e in order do
			if e.phase == "open" and not e.pinned and not e.dead and e.finished_ms ~= nil then
				local at = (e.finished_ms :: number) + GRACE_MS
				if at > clock and (soonest == nil or at < soonest) then
					soonest = at
				end
			end
		end
		return soonest
	end

	return {
		config = function(): Config
			return { enabled = cfg.enabled, limit = cfg.limit }
		end,
		toggle = function()
			cfg.enabled = not cfg.enabled
		end,
		cycle_limit = function()
			cfg.limit = next_limit(cfg.limit)
		end,
		observe = observe,
		finish_parent = finish_parent,
		parent_closed = parent_closed,
		pane_closed = pane_closed,
		action = action,
		reconcile = reconcile,
		next_expiry = next_expiry,
	}
end

return {
	new = new,
	placement = placement,
}
