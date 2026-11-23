--!strict
-- Wingman native UI: the pickers, prompts, Files button and status segments that steer wingman's agents and queue
-- from Tern's own chrome (palette, Files pane header, status bar). The pure helpers at the top take plain tables, so
-- tests/native_ui_fixture.luau exercises them without Tern; `new` binds them to a host (`tern`) and the control plane.
-- Every answer of `cx:pick`/`cx:prompt` arrives with a fresh cx; the click's cx is never used after a modal.

export type Row = {
	pane: number,
	title: string,
	state: string,
	queued: number,
	fault: string?,
	place: string?, -- "parked" | "pip" | "tab" | "split"; nil for an agent bound to no owner
	model: string?,
	cwd: string?,
	same_tab: boolean?,
	current: boolean,
}

local Queue = require("./queue")
export type QueuedItem = Queue.Snapshot

export type Segment = { text: string, icon: string?, tone: string?, command: string? }

export type NativeBridge = {
	owners: () -> { [number]: number },
	queued_dispatches: (pane: number) -> number,
	queued_callbacks: (pane: number) -> number,
	fault: (pane: number) -> string?,
	unqueue: (cx: any, pane: number) -> number,
	queue_prompt: (id: number) -> string?,
	enqueue_prompt: (cx: any, pane: number, prompt: string) -> (boolean, string?, boolean?, number?, number?),
	edit_queued: (id: number, prompt: string) -> (boolean, string?),
	promote_queued: (id: number) -> (boolean, string?),
	cancel_queued_id: (id: number) -> (boolean, string?),
	all_queued: (cx: any) -> { QueuedItem },
	move_queued: (cx: any, id: number, to_pane: number) -> (boolean, string?, boolean?),
}

export type Deps = {
	host: any, -- `tern`: command, files.button and chrome.status
	plugin_id: string,
	bridge: NativeBridge,
	states: { [number]: string }, -- cached agent states, kept by the radar's events
	titles: { [number]: string },
	live_count: () -> number, -- agents not exited; O(1)
	shutting_down: () -> boolean,
	changed: () -> (),
	log: (what: string, err: any) -> (),
}

local M = {}

------------------------------------------------------------------------------------------------------------------------
-- Pure helpers

--- The last two path components, `…/` before them when more were cut; nil for an unknown cwd.
function M.short_cwd(cwd: string?): string?
	if cwd == nil or cwd == "" then
		return nil
	end
	local parts: { string } = {}
	for part in string.gmatch(cwd, "[^/]+") do
		table.insert(parts, part)
	end
	if #parts == 0 then
		return "/"
	end
	if #parts <= 2 then
		return (string.gsub(cwd, "(.)/+$", "%1"))
	end
	return "…/" .. parts[#parts - 1] .. "/" .. parts[#parts]
end

local function group_of(row: Row): string
	return if row.place == "parked" then "Parked" elseif row.same_tab or row.current then "Current tab" else "Other tabs"
end

local group_order = { ["Current tab"] = 1, ["Other tabs"] = 2, Parked = 3 }

function M.switch_items(rows: { Row }): { any }
	local sorted = table.clone(rows)
	table.sort(sorted, function(a: Row, b: Row): boolean
		local ga, gb = group_order[group_of(a)], group_order[group_of(b)]
		return if ga == gb then a.pane < b.pane else ga < gb
	end)
	local items: { any } = {}
	for _, r in sorted do
		local detail: { string } = { r.state }
		if r.queued > 0 then
			table.insert(detail, "Q" .. r.queued)
		end
		if r.fault ~= nil then
			table.insert(detail, "fault")
		end
		if r.place ~= nil then
			table.insert(detail, r.place)
		end
		if r.model ~= nil then
			table.insert(detail, r.model)
		end
		local cwd = M.short_cwd(r.cwd)
		if cwd ~= nil then
			table.insert(detail, cwd)
		end
		table.insert(items, {
			label = r.title,
			detail = table.concat(detail, " · "),
			group = group_of(r),
			current = r.current,
			pane = r.pane,
		})
	end
	return items
end

--- Picker items for every queued prompt, grouped by the agent it waits for, in slot order.
function M.queue_items(queued: { QueuedItem }, title_of: (pane: number) -> string): { any }
	local sorted = table.clone(queued)
	table.sort(sorted, function(a: QueuedItem, b: QueuedItem): boolean
		if a.pane ~= b.pane then
			return a.pane < b.pane
		end
		return a.position < b.position
	end)
	local items: { any } = {}
	for _, q in sorted do
		table.insert(items, {
			label = string.format("#%d · %s", q.id, q.preview),
			detail = "slot " .. q.position,
			group = title_of(q.pane),
			id = q.id,
			pane = q.pane,
		})
	end
	return items
end

--- The second menu of a queued prompt.
function M.action_items(id: number, position: number?, can_move: boolean?): { any }
	local items: { any } = {}
	if position == nil or position > 1 then
		table.insert(items, { label = "Move to top", act = "top", id = id })
	end
	table.insert(items, { label = "Edit prompt", act = "edit", id = id })
	if can_move ~= false then
		table.insert(items, { label = "Move to another agent", act = "move", id = id })
	end
	table.insert(items, { label = "Cancel task", act = "cancel", id = id })
	table.insert(items, { label = "Focus agent", act = "focus", id = id })
	return items
end

--- Focused live agent, else the only live agent in the focused one's tab, else the only one in the window; nil
--- when the choice is the user's. `tab_of` is the only native read, made for the live agents of the focused tab.
function M.choose_target(live: { Row }, focused: number?, tab_of: (pane: number) -> number?): number?
	for _, a in live do
		if a.pane == focused then
			return a.pane
		end
	end
	if focused ~= nil then
		local tab = tab_of(focused)
		local here: number? = nil
		local count = 0
		for _, a in live do
			if tab ~= nil and tab_of(a.pane) == tab then
				count += 1
				here = a.pane
			end
		end
		if count == 1 then
			return here
		end
	end
	if #live == 1 then
		return live[1].pane
	end
	return nil
end

--- The prompt's starting text for a Files pane: the selected paths (the folder when none), relative to the folder
--- when inside it; nil when the pane shows nothing.
function M.files_prefill(root: string?, selection: { string }): string?
	local windows = root ~= nil and (string.match(root, "^%a:") ~= nil or string.sub(root, 1, 2) == "\\\\")
	local function comparable(path: string): string
		return if windows then string.lower((string.gsub(path, "\\", "/"))) else path
	end
	local prefix = if root and root ~= "" then (string.gsub(comparable(root), "/+$", "")) .. "/" else nil
	local function quote(path: string): string
		return if string.find(path, '[%s"]') then '"' .. string.gsub(path, '"', '\\"') .. '"' else path
	end
	if #selection == 0 then
		return if root and root ~= "" then quote(root) .. " " else nil
	end
	local shown: { string } = {}
	for _, path in selection do
		local normalized = comparable(path)
		local relative = if prefix and string.sub(normalized, 1, #prefix) == prefix then string.sub(path, #prefix + 1) else path
		table.insert(shown, quote(if relative == "" then "." else relative))
	end
	return table.concat(shown, " ") .. " "
end

--- Status-bar segments of one agent: fault or waiting, then queued prompts and queued callbacks; nil for an unknown
--- or quiet agent.
function M.status_segments(
	state: string?,
	fault: string?,
	queued: number,
	callbacks: number,
	switch_action: string,
	queue_action: string
): { Segment }?
	if state == nil then
		return nil
	end
	local segments: { Segment } = {}
	if fault ~= nil then
		table.insert(segments, { text = "fault", icon = "alert-triangle", tone = "error", command = switch_action })
	elseif state == "waiting_input" then
		table.insert(segments, { text = "waiting", icon = "message-circle", tone = "warn", command = switch_action })
	end
	if queued > 0 then
		table.insert(segments, { text = "Q" .. queued, icon = "list", tone = "warn", command = queue_action })
	end
	if callbacks > 0 then
		table.insert(segments, { text = "↩" .. callbacks, tone = "muted", command = switch_action })
	end
	return if #segments > 0 then segments else nil
end

------------------------------------------------------------------------------------------------------------------------
-- Bound to a host

function M.new(d: Deps)
	local ui = {}
	local b = d.bridge
	local switch_action = "plugin." .. d.plugin_id .. ".toggle_panel"
	local queue_action = "plugin." .. d.plugin_id .. ".manage_queue"

	local function title_in(cx: any, pane: number): string
		local info = cx.session:pane(pane)
		if info ~= nil and info.title ~= "" then
			return info.title
		end
		return d.titles[pane] or ("pane " .. pane)
	end

	local function settled(cx: any, later: any): boolean
		return not d.shutting_down() and later ~= nil
	end

	function ui.report(cx: any, ok: boolean, err: string?, what: string)
		if not ok then
			cx:toast("error", "Wingman: " .. what .. " failed", err)
		end
		d.changed()
	end

	--- Live agents with everything the pickers show; native reads, so only from a command's run.
	function ui.live_rows(cx: any): { Row }
		local owners = b.owners()
		local focused = cx.session:focused()
		local rows: { Row } = {}
		for _, a in cx.agents:list() do
			if a.state == "exited" then
				continue
			end
			local info = cx.session:pane(a.pane)
			local place: string? = nil
			if info ~= nil then
				local owner = owners[a.pane]
				if info.parked == true then
					place = "parked"
				elseif info.floating == true then
					place = "pip"
				elseif owner ~= nil then
					place = if info.tab ~= cx.session:tab_of(owner) then "tab" else "split"
				end
			end
			local model: any = a.model
			table.insert(rows, {
				pane = a.pane,
				title = title_in(cx, a.pane),
				state = a.state :: string,
				queued = b.queued_dispatches(a.pane),
				fault = b.fault(a.pane),
				place = place,
				model = if type(model) == "string" and model ~= "" then model else nil,
				cwd = a.cwd,
				same_tab = focused ~= nil and info ~= nil and info.tab ~= nil and info.tab == cx.session:tab_of(focused),
				current = a.pane == focused,
			})
		end
		return rows
	end

	--- Unparks when needed, then focuses.
	function ui.reveal(cx: any, pane: number)
		local info = cx.session:pane(pane)
		if info == nil then
			cx:toast("info", "Wingman: that agent is gone")
			return
		end
		if info.parked == true then
			local ok, err = cx.layout:unpark(pane)
			if not ok then
				cx:toast("error", "Wingman: Unpark failed", err)
				return
			end
		end
		cx.layout:focus(pane)
	end

	function ui.ask_queue(cx: any, pane: number, prefill: string?)
		cx:prompt({
			value = prefill,
			placeholder = "Queue a prompt for " .. title_in(cx, pane),
			icon = "list",
			action = "queue",
		}):next(function(text: string?, err: string?, later: any)
			if not settled(cx, later) then
				return
			end
			if err then
				later:toast("error", "Wingman: Queue Prompt failed", err)
				return
			end
			if text == nil or string.match(text, "^%s*$") then
				return
			end
			local ok, qerr, queued, id, position = b.enqueue_prompt(later, pane, text)
			if not ok then
				later:toast("error", "Wingman: Queue Prompt failed", qerr)
			elseif queued and id ~= nil then
				later:toast("info", string.format("Wingman: queued #%d · slot %d", id, position or 1), title_in(later, pane))
			else
				later:toast("info", "Wingman: prompt sent", title_in(later, pane))
			end
			d.changed()
		end)
	end

	function ui.edit_queue(cx: any, id: number)
		local original = b.queue_prompt(id)
		if original == nil then
			cx:toast("info", "Wingman: queued prompt #" .. id .. " is no longer queued")
			d.changed()
			return
		end
		cx:prompt({ value = original, placeholder = "Edit queued prompt #" .. id, icon = "list", action = "save" }):next(
			function(text: string?, err: string?, later: any)
				if not settled(cx, later) then
					return
				end
				if err then
					later:toast("error", "Wingman: Edit failed", err)
					return
				end
				if text == nil or string.match(text, "^%s*$") or text == original then
					return
				end
				local current = b.queue_prompt(id)
				if current == nil then
					later:toast("info", "Wingman: queued prompt #" .. id .. " was sent or cancelled before your edit")
					d.changed()
					return
				end
				if current ~= original then
					later:toast("info", "Wingman: queued prompt #" .. id .. " changed", "Reopen Edit to see the current prompt.")
					return
				end
				local ok, eerr = b.edit_queued(id, text)
				ui.report(later, ok, eerr, "Edit")
				if ok then
					later:toast("info", "Wingman: updated queued prompt #" .. id)
				end
			end
		)
	end

	--- The agent a prompt is for: focused, only one in the tab or window, else the user's pick. `prefill` starts the
	--- prompt's text.
	function ui.queue_prompt(cx: any, prefill: string?)
		local rows = ui.live_rows(cx)
		if #rows == 0 then
			cx:toast("info", "Wingman: no live agent to queue a prompt for")
			return
		end
		local chosen = M.choose_target(rows, cx.session:focused(), function(pane: number): number?
			return cx.session:tab_of(pane)
		end)
		if chosen ~= nil then
			ui.ask_queue(cx, chosen, prefill)
			return
		end
		cx:pick({ items = M.switch_items(rows), placeholder = "Queue a prompt for…", icon = "list", action = "queue" }):next(
			function(item: any, err: string?, later: any)
				if not settled(cx, later) then
					return
				end
				if err then
					later:toast("error", "Wingman: Queue Prompt failed", err)
				elseif item ~= nil and type(item.pane) == "number" then
					ui.ask_queue(later, item.pane, prefill)
				end
			end
		)
	end

	function ui.switch_agent(cx: any)
		local rows = ui.live_rows(cx)
		if #rows == 0 then
			cx:toast("info", "Wingman: no live agent to switch to")
			return
		end
		cx:pick({ items = M.switch_items(rows), placeholder = "Switch to agent…", icon = "layers", action = "focus" }):next(
			function(item: any, err: string?, later: any)
				if not settled(cx, later) then
					return
				end
				if err then
					later:toast("error", "Wingman: Switch Agent failed", err)
				elseif item ~= nil and type(item.pane) == "number" then
					ui.reveal(later, item.pane)
				end
			end
		)
	end

	local function move_queued(cx: any, id: number, from: number)
		local rows = ui.live_rows(cx)
		for _, r in rows do
			r.current = r.pane == from
		end
		if #rows == 0 then
			cx:toast("info", "Wingman: no live agent to move the prompt to")
			return
		end
		cx:pick({ items = M.switch_items(rows), placeholder = "Move queued prompt #" .. id .. " to…", icon = "list", action = "move" }):next(
			function(item: any, err: string?, later: any)
				if not settled(cx, later) then
					return
				end
				if err then
					later:toast("error", "Wingman: Move failed", err)
					return
				end
				if item == nil or type(item.pane) ~= "number" then
					return
				end
				if b.queue_prompt(id) == nil then
					later:toast("info", "Wingman: queued prompt #" .. id .. " was sent or cancelled")
					d.changed()
					return
				end
				local ok, merr, dispatched = b.move_queued(later, id, item.pane)
				ui.report(later, ok, merr, "Move")
				if ok then
					local target = title_in(later, item.pane)
					if dispatched then
						later:toast("info", "Wingman: prompt #" .. id .. " sent immediately", target)
					else
						later:toast("info", "Wingman: prompt #" .. id .. " queued", target)
					end
				end
			end
		)
	end

	local function act_on_queued(cx: any, id: number, pane: number, act: string)
		if b.queue_prompt(id) == nil then
			cx:toast("info", "Wingman: queued prompt #" .. id .. " is no longer queued")
			d.changed()
		elseif act == "top" then
			local ok, err = b.promote_queued(id)
			ui.report(cx, ok, err, "Move to top")
		elseif act == "edit" then
			ui.edit_queue(cx, id)
		elseif act == "move" then
			move_queued(cx, id, pane)
		elseif act == "cancel" then
			local ok, err = b.cancel_queued_id(id)
			ui.report(cx, ok, err, "Cancel queued prompt")
		elseif act == "focus" then
			ui.reveal(cx, pane)
		end
	end

	function ui.manage_queue(cx: any)
		local queued = b.all_queued(cx)
		if #queued == 0 then
			cx:toast("info", "Wingman: no queued prompts")
			return
		end
		local items = M.queue_items(queued, function(pane: number): string
			return title_in(cx, pane)
		end)
		cx:pick({ items = items, placeholder = "Queued prompts…", icon = "list", action = "manage" }):next(
			function(item: any, err: string?, later: any)
				if not settled(cx, later) then
					return
				end
				if err then
					later:toast("error", "Wingman: Manage Queue failed", err)
					return
				end
				if item == nil or type(item.id) ~= "number" or type(item.pane) ~= "number" then
					return
				end
				local id, pane = item.id :: number, item.pane :: number
				local task: QueuedItem? = nil
				for _, entry in b.all_queued(later) do
					if entry.id == id then
						task = entry
						break
					end
				end
				if task == nil then
					later:toast("info", "Wingman: task is no longer queued")
					return
				end
				pane = task.pane
				later:pick({ items = M.action_items(id, task.position, #ui.live_rows(later) > 1), placeholder = "Queued prompt #" .. id, icon = "list", action = "run" }):next(
					function(choice: any, cerr: string?, again: any)
						if not settled(later, again) then
							return
						end
						if cerr then
							again:toast("error", "Wingman: Manage Queue failed", cerr)
						elseif choice ~= nil and type(choice.act) == "string" then
							act_on_queued(again, id, pane, choice.act)
						end
					end
				)
			end
		)
	end

	local function guarded(name: string, title: string, fn: (cx: any) -> ()): (cx: any) -> ()
		return function(cx: any)
			local ok, err = pcall(function(): any
				fn(cx)
				return nil
			end)
			if not ok then
				d.log(name, err)
				cx:toast("error", title .. " failed", tostring(err))
			end
		end
	end

	local function any_queued(): boolean
		for pane in d.states do
			if b.queued_dispatches(pane) > 0 then
				return true
			end
		end
		return false
	end

	function ui.register()
		local host = d.host
		host.command({
			id = "switch_agent",
			title = "Wingman: Switch / Search Agents",
			icon = "layers",
			available = function(_cx: any): boolean
				return d.live_count() > 0
			end,
			run = guarded("switch_agent", "Wingman: Switch Agent", ui.switch_agent),
		})
		host.command({
			id = "manage_queue",
			title = "Wingman: Search / Manage Queue",
			icon = "list",
			available = function(_cx: any): boolean
				return any_queued()
			end,
			run = guarded("manage_queue", "Wingman: Manage Queue", ui.manage_queue),
		})
		host.command({
			id = "queue_prompt",
			title = "Wingman: Queue Prompt for Agent",
			icon = "list",
			available = function(_cx: any): boolean
				return d.live_count() > 0
			end,
			run = guarded("queue_prompt", "Wingman: Queue Prompt", function(cx: any)
				ui.queue_prompt(cx, nil)
			end),
		})
		host.files.button({
			id = "send_to_agent",
			title = "Send selection to Agent",
			icon = "list",
			run = function(files: any, cx: any)
				local ok, err = pcall(function(): any
					local text = M.files_prefill(files.root, files.selection)
					if text == nil then
						cx:toast("info", "Wingman: the Files pane shows no folder or selection")
						return
					end
					ui.queue_prompt(cx, text)
					return nil
				end)
				if not ok then
					d.log("files button", err)
					cx:toast("error", "Wingman: Queue Prompt failed", tostring(err))
				end
			end,
		})
		local last_state: string?
		local last_fault: string?
		local last_queued, last_callbacks = 0, 0
		local cached: { Segment }? = nil
		host.chrome.status(function(pane: any): { Segment }?
			local p = pane.pane :: number
			local state = d.states[p]
			if state == nil then
				return nil
			end
			local fault, queued, callbacks = b.fault(p), b.queued_dispatches(p), b.queued_callbacks(p)
			if state ~= last_state or fault ~= last_fault or queued ~= last_queued or callbacks ~= last_callbacks then
				last_state, last_fault, last_queued, last_callbacks = state, fault, queued, callbacks
				cached = M.status_segments(state, fault, queued, callbacks, switch_action, queue_action)
			end
			return cached
		end)
	end

	return ui
end

return M
