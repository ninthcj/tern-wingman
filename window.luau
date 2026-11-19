--!strict
-- Wingman: Bidirectional event-driven WindowCx.agents TSP bridge & ownership graph for coding agents in Tern.

local is_windows = (tern.runtime.os == "windows")
local SEP = if is_windows then "\\" else "/"
local runtime_dir = tern.getenv("XDG_RUNTIME_DIR")
local home_dir = tern.getenv("HOME") or tern.getenv("USERPROFILE")
local local_app_data = tern.getenv("LOCALAPPDATA") or tern.getenv("TEMP")
local daemon_socket = tern.getenv("TERN_DAEMON_SOCKET") or tern.getenv("TERN_PANE_SOCKET")

local function resolve_ipc_dir(): string
	if is_windows then
		local base = if local_app_data and local_app_data ~= "" then local_app_data else "C:\\Temp"
		return base .. "\\tern-wingman"
	end
	if runtime_dir and runtime_dir ~= "" and #runtime_dir <= 72 then
		return runtime_dir .. "/tern-wingman"
	end
	local fallback = (home_dir or "/tmp") .. "/.cache/tern-wingman"
	if #fallback <= 72 then
		return fallback
	end
	return "/tmp/tern-wingman-" .. tostring(tern.getenv("USER") or "user")
end

local ipc_dir = resolve_ipc_dir()
local KV_BINDINGS = "bindings_v1"
local KV_CALLBACK_CFG = "auto_callback_v1"
local KV_WAITING = "notified_waiting_v1"

type WaitEntry = {
	cids: { number },
	started_ms: number,
	saw_working: boolean,
	idle_since: number?,
	pending_prompt: string?,
	ask_deadline: number?,
}

type QueuedDispatch = {
	cid: number?,
	anchor: number,
	prompt: string,
	pip_corner: string?,
}

-- Explicit ownership bijection: anchor_pane (supervisor, e.g. agy) -> wingman_pane (worker, e.g. omp)
local bindings: { [number]: number } = {}
-- Active in-flight turn waits keyed by wingman pane_id
local pending_waits: { [number]: WaitEntry } = {}
-- Native per-pane FIFO dispatch queue when target_pane is busy (`working`)
local queued_dispatches: { [number]: { QueuedDispatch } } = {}
-- Native per-owner FIFO callback queue when owner_pane is busy (`working` / `waiting_input`)
local queued_callbacks: { [number]: { string } } = {}
-- Tracks whether a wingman pane is executing an unsolicited turn (no active `pending_waits` waiter)
local unsolicited_working: { [number]: boolean } = {}
-- Tracks whether a wingman pane already called `report` (`kind ~= "progress"`) during the current turn
local reported_in_turn: { [number]: boolean } = {}
-- Dedup key of the last `waiting_input` or `fault` escalation pushed to the owner, per wingman pane (persisted)
local notified_waiting: { [number]: string } = {}
-- Panes intentionally interrupted via `wingman.py interrupt` (suppresses fault escalation until next turn)
local manual_interrupt: { [number]: boolean } = {}

-- Auto-callback policy (default ON; supports global default + per-owner overrides)
local default_auto_callback = true
local owner_auto_callback: { [number]: boolean } = {}

local mux_child: Child? = nil
local unloading = false
local watchdog_armed = false

local function save_bindings()
	local ser: { [string]: number } = {}
	local any_entry = false
	for anchor_id, worker_id in pairs(bindings) do
		ser[tostring(anchor_id)] = worker_id
		any_entry = true
	end
	pcall(function()
		if any_entry then
			tern.kv.set(KV_BINDINGS, ser)
		else
			tern.kv.set(KV_BINDINGS, nil)
		end
	end)
end

local function load_bindings()
	local ok, raw = pcall(tern.kv.get, KV_BINDINGS)
	if ok and type(raw) == "table" then
		for k, v in pairs(raw) do
			local aid = tonumber(k)
			local wid = tonumber(v)
			if aid and wid and aid ~= wid then
				bindings[aid] = wid
			end
		end
	end
end

local function save_callback_cfg()
	local overrides: { [string]: boolean } = {}
	for aid, val in pairs(owner_auto_callback) do
		overrides[tostring(aid)] = val
	end
	pcall(function()
		tern.kv.set(KV_CALLBACK_CFG, {
			default = default_auto_callback,
			owners = overrides,
		})
	end)
end

local function load_callback_cfg()
	local ok, raw = pcall(tern.kv.get, KV_CALLBACK_CFG)
	if ok and type(raw) == "table" then
		if type(raw.default) == "boolean" then
			default_auto_callback = raw.default
		end
		if type(raw.owners) == "table" then
			for k, v in pairs(raw.owners) do
				local aid = tonumber(k)
				if aid and type(v) == "boolean" then
					owner_auto_callback[aid] = v
				end
			end
		end
	end
end

local function save_waiting()
	local ser: { [string]: string } = {}
	for pid, key in pairs(notified_waiting) do
		ser[tostring(pid)] = key
	end
	pcall(function()
		tern.kv.set(KV_WAITING, if next(ser) ~= nil then ser else nil)
	end)
end

local function load_waiting()
	local ok, raw = pcall(tern.kv.get, KV_WAITING)
	if ok and type(raw) == "table" then
		for k, v in pairs(raw) do
			local pid = tonumber(k)
			if pid and type(v) == "string" then
				notified_waiting[pid] = v
			end
		end
	end
end

local function clear_waiting(pane_id: number)
	if notified_waiting[pane_id] ~= nil then
		notified_waiting[pane_id] = nil
		save_waiting()
	end
end

local function is_auto_callback_enabled(owner_pane: number?): boolean
	if owner_pane ~= nil and owner_auto_callback[owner_pane] ~= nil then
		return owner_auto_callback[owner_pane] :: boolean
	end
	return default_auto_callback
end

local function prune_bindings(cx: WindowCx)
	local dirty = false
	for aid, wid in pairs(bindings) do
		if aid == wid or cx.session:pane(aid) == nil or cx.session:pane(wid) == nil then
			bindings[aid] = nil
			dirty = true
		end
	end
	if dirty then
		save_bindings()
	end
	local cb_dirty = false
	for aid, _ in pairs(owner_auto_callback) do
		if cx.session:pane(aid) == nil then
			owner_auto_callback[aid] = nil
			cb_dirty = true
		end
	end
	if cb_dirty then
		save_callback_cfg()
	end
	local w_dirty = false
	for pid, _ in pairs(notified_waiting) do
		if cx.session:pane(pid) == nil then
			notified_waiting[pid] = nil
			w_dirty = true
		end
	end
	if w_dirty then
		save_waiting()
	end
end

local function get_bound_wingman(cx: WindowCx, anchor: number): number?
	prune_bindings(cx)
	return bindings[anchor]
end

local function owner_of_pane(cx: WindowCx, pane_id: number): number?
	prune_bindings(cx)
	for aid, wid in pairs(bindings) do
		if wid == pane_id then
			return aid
		end
	end
	return nil
end

local function bind_wingman(anchor: number, worker: number)
	if anchor == worker then
		return
	end
	for aid, wid in pairs(bindings) do
		if wid == worker and aid ~= anchor then
			bindings[aid] = nil
		end
	end
	if bindings[anchor] ~= worker then
		bindings[anchor] = worker
		save_bindings()
	end
end

local function unbind_pane(pane_id: number)
	local dirty = false
	if bindings[pane_id] ~= nil then
		bindings[pane_id] = nil
		dirty = true
	end
	for aid, wid in pairs(bindings) do
		if wid == pane_id then
			bindings[aid] = nil
			dirty = true
		end
	end
	if dirty then
		save_bindings()
	end
	if owner_auto_callback[pane_id] ~= nil then
		owner_auto_callback[pane_id] = nil
		save_callback_cfg()
	end
end

local function same_daemon(req_socket: any): boolean
	if req_socket == nil or req_socket == tern.json.null or req_socket == "" then
		return true
	end
	if daemon_socket and daemon_socket ~= "" then
		return req_socket == daemon_socket
	end
	if type(req_socket) ~= "string" then
		return false
	end
	return string.sub(req_socket, -12) == "/daemon.sock" or string.sub(req_socket, -12) == "\\daemon.sock"
end

local function send_mux(cid: number, reply: any, keep_open: boolean?)
	local child = mux_child
	if not child then
		return
	end
	local line = tern.json.encode({
		id = cid,
		reply = reply,
		keep_open = keep_open == true,
	}) .. "\n"
	pcall(function()
		child:write(line)
	end)
end

local function find_agent_info(cx: WindowCx, pane_id: number): AgentBlock?
	for _, a in ipairs(cx.agents:list()) do
		if a.pane == pane_id then
			return a
		end
	end
	return nil
end

local function strip_turn_footer(text: string): string
	-- Trim Tern/omp UI footer chrome like "\n·\n6m44s · 445 tok · $0.06 this turn" or "\n19s · 202K tok this turn"
	local cleaned = string.gsub(text, "\n·\n[^\n]* this turn%s*$", "")
	cleaned = string.gsub(cleaned, "\n[^\n]* this turn%s*$", "")
	return cleaned
end

local function collect_turn_output(cx: WindowCx, pane_id: number): (string?, any)
	local info = find_agent_info(cx, pane_id)
	local raw_last: any = info and info.last_message or nil
	local last_msg: string? = if type(raw_last) == "string" then raw_last else nil
	local ok_t, msgs = pcall(function()
		return cx.agents:transcript(pane_id, { last = 6 })
	end)
	local transcript = (ok_t and type(msgs) == "table") and tern.json.array(msgs) or tern.json.array()
	if (not last_msg or last_msg == "") and ok_t and type(msgs) == "table" then
		for i = #msgs, 1, -1 do
			if msgs[i].role == "assistant" and type(msgs[i].text) == "string" and msgs[i].text ~= "" then
				last_msg = msgs[i].text
				break
			end
		end
	end
	if last_msg and last_msg ~= "" then
		last_msg = strip_turn_footer(last_msg)
	end
	return last_msg, transcript
end

local ensure_watchdog: () -> ()

local function has_active_timers(): boolean
	return next(pending_waits) ~= nil or next(queued_dispatches) ~= nil or next(queued_callbacks) ~= nil
end

local function flush_queued_callbacks(cx: WindowCx, owner_pane: number): boolean
	local q = queued_callbacks[owner_pane]
	if not q or #q == 0 then
		queued_callbacks[owner_pane] = nil
		return false
	end
	if cx.session:pane(owner_pane) == nil then
		queued_callbacks[owner_pane] = nil
		return false
	end
	local ainfo = find_agent_info(cx, owner_pane)
	if not ainfo or ainfo.state ~= "idle" then
		return false
	end
	local combined = table.concat(q, "\n\n---\n\n")
	local ok_ask = pcall(function()
		cx.agents:ask(owner_pane, combined)
	end)
	if ok_ask then
		queued_callbacks[owner_pane] = nil
		return true
	end
	return false
end

local function deliver_to_owner(
	cx: WindowCx,
	owner_pane: number,
	worker_pane: number,
	tag: string,
	body: string
): (boolean, boolean, number)
	local formatted = string.format("[Wingman %s · pane %d]\n%s", tag, worker_pane, body)
	local existing_q = queued_callbacks[owner_pane]
	local ainfo = find_agent_info(cx, owner_pane)
	if ainfo ~= nil and ainfo.state == "idle" and (existing_q == nil or #existing_q == 0) then
		local ok_ask = pcall(function()
			cx.agents:ask(owner_pane, formatted)
		end)
		if ok_ask then
			return true, false, 0
		end
	end
	if not existing_q then
		existing_q = {}
		queued_callbacks[owner_pane] = existing_q
	end
	table.insert(existing_q, formatted)
	ensure_watchdog()
	return false, true, #existing_q
end

local INTERACTIVE_ROLES = {
	["omp.ask.card"] = true,
	["omp.editor.ask.approval"] = true,
	["omp.overlay.hook-input"] = true,
	["omp.overlay.hook-select"] = true,
}
local WIRE_KINDS = { button = true, list = true, input = true, editor = true, el = true }

local function walk_nodes(node: any, depth: number, visit: (any) -> boolean): boolean
	if type(node) ~= "table" or depth > 16 then
		return false
	end
	if visit(node) then
		return true
	end
	local children = node.c
	if type(children) == "table" then
		for _, child in ipairs(children) do
			if type(child) == "table" and walk_nodes(child, depth + 1, visit) then
				return true
			end
		end
	end
	return false
end

local function find_interactive_root(tree: any): (string?, string?)
	if type(tree) ~= "table" then
		return nil, nil
	end
	local found_id: string?, found_role: string? = nil, nil
	local function visit(n: any): boolean
		local p = n.p
		if type(p) == "table" and INTERACTIVE_ROLES[p.role] and n.id ~= nil then
			found_id, found_role = tostring(n.id), p.role
			return true
		end
		return false
	end
	for _, key in ipairs({ "layer", "main", "dock" }) do
		if walk_nodes(tree[key], 0, visit) then
			break
		end
	end
	return found_id, found_role
end

local function spans_to_text(v: any): string
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

local function format_tsp_subtree(node: any, indent: string, out: { string }, depth: number)
	if type(node) ~= "table" or depth > 16 or #out >= 400 then
		return
	end
	local id = if node.id ~= nil then tostring(node.id) else "-"
	local kind = if node.k ~= nil then tostring(node.k) else "node"
	local p = node.p
	local tags: { string } = {}
	local text_parts: { string } = {}
	if type(p) == "table" then
		if p.tone == "accent" or p.on == true or p.icon == "check" then
			table.insert(tags, "selected")
		end
		if type(p.actions) == "table" and type(p.actions.click) == "string" then
			table.insert(tags, "click=" .. p.actions.click)
		end
		for _, field in ipairs({ "text", "spans", "label", "detail", "value" }) do
			local s = spans_to_text(p[field])
			if s ~= "" then
				table.insert(text_parts, s)
			end
		end
	end
	local meta = if #tags > 0 then " [" .. table.concat(tags, ", ") .. "]" else ""
	local content = if #text_parts > 0 then ": " .. table.concat(text_parts, " — ") else ""
	table.insert(out, string.format("%s%s %s%s%s", indent, id, kind, meta, content))
	local children = node.c
	if type(children) == "table" then
		for _, child in ipairs(children) do
			format_tsp_subtree(child, indent .. "  ", out, depth + 1)
		end
	end
end

local function find_node_by_id(tree: any, target_id: string): any
	local hit: any = nil
	for _, key in ipairs({ "layer", "main", "dock" }) do
		if walk_nodes(tree[key], 0, function(n: any): boolean
			if n.id ~= nil and tostring(n.id) == target_id then
				hit = n
				return true
			end
			return false
		end) then
			break
		end
	end
	return hit
end

local function build_waiting_summary(cx: WindowCx, pane_id: number): (string, string)
	local ok_tree, tree = pcall(function()
		return cx.session:surface(pane_id, { as = "table", nodes = 1500 })
	end)
	local root_id, role = nil, nil
	local surface_text = ""
	if ok_tree and type(tree) == "table" then
		root_id, role = find_interactive_root(tree)
		local target_node = if root_id ~= nil then find_node_by_id(tree, root_id) else nil
		if target_node ~= nil then
			local lines: { string } = {}
			format_tsp_subtree(target_node, "", lines, 0)
			surface_text = table.concat(lines, "\n")
		end
	end
	if surface_text == "" then
		local ok_txt, txt = pcall(function()
			return cx.session:surface(pane_id, { as = "text", root = root_id, max_chars = 12000 })
		end)
		surface_text = if ok_txt and txt ~= nil then tostring(txt) else "(surface unavailable)"
	end
	local parts: { string } = {}
	local ok_tr, msgs = pcall(function()
		return cx.agents:transcript(pane_id, { last = 2 })
	end)
	if ok_tr and type(msgs) == "table" then
		for i = #msgs, 1, -1 do
			local m = msgs[i]
			if m.role == "assistant" then
				if type(m.text) == "string" and m.text ~= "" and not string.find(surface_text, m.text, 1, true) then
					table.insert(parts, "Last assistant message:\n" .. string.sub(m.text, 1, 1000))
				end
				if type(m.tools) == "table" and #m.tools > 0 then
					table.insert(parts, "Tool call metadata:\n" .. string.sub(tern.json.encode(m.tools), 1, 4000))
				end
				break
			end
		end
	end
	table.insert(parts, string.format("Interactive surface (%s · root %s):\n%s", tostring(role or "unknown"), tostring(root_id or "-"), surface_text))
	table.insert(parts, string.format(
		"Inspect: `wingman.py surface --pane %d [--json]`. Answer via `wingman.py event --pane %d '<json-event>' ...`:\n"
			.. "- Pick option & submit: `'{\"ev\":\"action\",\"id\":\"ui\",\"act\":\"pick:0:0\"}' '{\"ev\":\"action\",\"id\":\"ui.actions/submit\",\"act\":\"submit\"}'`\n"
			.. "- Open folded field / fill `Other…` or text input: `open:<idx>` -> `{\"ev\":\"select\",\"id\":\"<list_id>\",\"item\":\"other\"}` -> check `<input_id>` via `surface` -> `{\"ev\":\"edit\",\"id\":\"<input_id>\",\"from\":0,\"to\":0,\"text\":\"...\",\"cursor\":<utf16_len>,\"len\":0}`\n"
			.. "- Add option note: `{\"ev\":\"action\",\"id\":\"<item_id>\",\"act\":\"note\"}` -> `edit` `<editor_id>` -> `{\"ev\":\"action\",\"id\":\"ui.actions/save-note\",\"act\":\"save-note\"}`\n"
			.. "Decide technical/architectural questions yourself; consult the user first on product/scope/cost trade-offs.",
		pane_id, pane_id
	))
	return tostring(role or "waiting") .. ":" .. tostring(root_id or "root"), table.concat(parts, "\n\n")
end

local function notify_waiting_input(cx: WindowCx, worker_pane: number)
	tern.timer(120, function(later_cx: WindowCx?)
		local lcx = later_cx or cx
		local ainfo = find_agent_info(lcx, worker_pane)
		if not ainfo or ainfo.state ~= "waiting_input" or pending_waits[worker_pane] ~= nil then
			return
		end
		local owner = owner_of_pane(lcx, worker_pane)
		if owner == nil or not is_auto_callback_enabled(owner) then
			return
		end
		local key, body = build_waiting_summary(lcx, worker_pane)
		if notified_waiting[worker_pane] == key then
			return
		end
		notified_waiting[worker_pane] = key
		save_waiting()
		deliver_to_owner(lcx, owner, worker_pane, "waiting_input", body)
	end)
end

local function node_text(node: any): string
	local lines: { string } = {}
	walk_nodes(node, 0, function(n: any): boolean
		local p = n.p
		if type(p) == "table" then
			for _, field in ipairs({ "text", "spans", "label", "detail", "value" }) do
				local s = spans_to_text(p[field])
				if s ~= "" then
					table.insert(lines, s)
				end
			end
		end
		return #lines >= 60
	end)
	return table.concat(lines, "\n")
end

local function inspect_fault_surface(cx: WindowCx, pane_id: number): (boolean, string?, string?)
	local ok_tree, tree = pcall(function()
		return cx.session:surface(pane_id, { as = "table", nodes = 1500 })
	end)
	if not ok_tree or type(tree) ~= "table" then
		return false, nil, nil
	end
	local has_retry_hint = false
	local has_retry_error = false
	local banner_text: string? = nil
	local abort_text: string? = nil
	local error_text: string? = nil
	walk_nodes(tree.dock, 0, function(n: any): boolean
		local role = type(n.p) == "table" and n.p.role or nil
		if role == "omp.hint.retry" then
			has_retry_hint = true
		elseif role == "omp.errorBanner" then
			banner_text = node_text(n)
		end
		return false
	end)
	local main_c = tree.main and tree.main.c
	local tail = if type(main_c) == "table" and #main_c > 0 then main_c[#main_c] else nil
	walk_nodes(tail, 0, function(n: any): boolean
		local role = type(n.p) == "table" and n.p.role or nil
		if role == "omp.error" then
			has_retry_error = true
			error_text = node_text(n)
			return true
		elseif role == "omp.assistant.abort" then
			abort_text = node_text(n)
			return true
		end
		return false
	end)
	-- Strictly require a genuine takeover-needed state (`F5 to retry` in dock or `omp.error` Retry card at tail).
	-- Plain user `Esc` aborts (`omp.assistant.abort` without `omp.hint.retry`) and non-blocking warnings are ignored.
	if not has_retry_hint and not has_retry_error then
		return false, nil, nil
	end
	local parts: { string } = {}
	if error_text and error_text ~= "" then
		table.insert(parts, error_text)
	end
	if abort_text and abort_text ~= "" then
		table.insert(parts, abort_text)
	end
	if banner_text and banner_text ~= "" then
		table.insert(parts, banner_text)
	end
	local summary = table.concat(parts, "\n")
	if summary == "" then
		summary = "(omp stopped and is waiting on `F5 to retry`)"
	end
	return true, "fault:" .. tostring(tail and tail.id or "dock") .. ":" .. string.sub(summary, 1, 120), summary
end

local function deliver_fault_if_needed(cx: WindowCx, worker_pane: number, fallback_reason: string?): boolean
	local owner = owner_of_pane(cx, worker_pane)
	if owner == nil or not is_auto_callback_enabled(owner) then
		return false
	end
	local has_fault, key, summary = inspect_fault_surface(cx, worker_pane)
	if not has_fault then
		if fallback_reason == nil then
			return false
		end
		key, summary = "fault:" .. fallback_reason, fallback_reason
	end
	if notified_waiting[worker_pane] == key then
		return false
	end
	notified_waiting[worker_pane] = key :: string
	save_waiting()
	local body = tostring(summary)
		.. "\n\nRecover: run `wingman.py retry --pane " .. worker_pane .. "` (sends native `/retry`, equivalent to F5) for transient stream/network/edit-preview glitches (up to 2-3 retries), or consult the user if it is a persistent quota/auth/config error."
	deliver_to_owner(cx, owner, worker_pane, "fault · retryable", body)
	return true
end

local function promote_next_queued(cx: WindowCx, pane_id: number)
	local q = queued_dispatches[pane_id]
	if not q or #q == 0 then
		queued_dispatches[pane_id] = nil
		return
	end
	local item = table.remove(q, 1) :: QueuedDispatch
	if #q == 0 then
		queued_dispatches[pane_id] = nil
	end

	local ok_ask, err_ask = pcall(function()
		cx.agents:ask(pane_id, item.prompt)
	end)
	if not ok_ask then
		if item.cid ~= nil then
			send_mux(item.cid, {
				ok = false,
				pane = pane_id,
				status = "failed",
				error = "queued cx.agents:ask failed: " .. tostring(err_ask),
				last_message = "",
				transcript = tern.json.array(),
			}, false)
		else
			deliver_to_owner(cx, item.anchor, pane_id, "auto-callback · failed", "queued cx.agents:ask failed: " .. tostring(err_ask))
		end
		promote_next_queued(cx, pane_id)
		return
	end

	bind_wingman(item.anchor, pane_id)
	if item.pip_corner and item.pip_corner ~= "" then
		pcall(function()
			cx.layout:float(pane_id, item.anchor, item.pip_corner, { focus = false })
		end)
	end
	reported_in_turn[pane_id] = false
	if item.cid ~= nil then
		unsolicited_working[pane_id] = false
		pending_waits[pane_id] = {
			cids = { item.cid },
			started_ms = tern.now(),
			saw_working = false,
			idle_since = nil,
			pending_prompt = nil,
			ask_deadline = nil,
		}
		ensure_watchdog()
	else
		unsolicited_working[pane_id] = true
	end
end

local function finish_wait(cx: WindowCx, pane_id: number, status: string, err_msg: string?)
	local w = pending_waits[pane_id]
	if not w then
		return
	end
	pending_waits[pane_id] = nil
	unsolicited_working[pane_id] = false
	reported_in_turn[pane_id] = false
	local last_msg, transcript = collect_turn_output(cx, pane_id)
	if #w.cids == 0 then
		local owner = owner_of_pane(cx, pane_id)
		if status == "waiting_input" then
			notify_waiting_input(cx, pane_id)
		elseif owner ~= nil then
			local body = err_msg or last_msg or ("(Wingman turn ended with " .. status .. ")")
			deliver_to_owner(cx, owner, pane_id, "auto-callback · " .. status, body)
		end
	else
		local payload = {
			ok = (status == "done" or status == "idle"),
			pane = pane_id,
			status = status,
			error = err_msg,
			last_message = last_msg or "",
			transcript = transcript,
		}
		for _, cid in ipairs(w.cids) do
			send_mux(cid, payload, false)
		end
	end
	if status == "done" or status == "idle" then
		promote_next_queued(cx, pane_id)
	else
		local q = queued_dispatches[pane_id]
		if q then
			queued_dispatches[pane_id] = nil
			for _, item in ipairs(q) do
				if item.cid ~= nil then
					send_mux(item.cid, {
						ok = false,
						pane = pane_id,
						status = status,
						error = err_msg or ("queued dispatch aborted: " .. status),
						last_message = last_msg or "",
						transcript = transcript,
					}, false)
				end
			end
		end
	end
end

local function drop_disconnected_cid(cid: number, cx: WindowCx?)
	for pane_id, w in pairs(pending_waits) do
		local kept = {}
		for _, existing in ipairs(w.cids) do
			if existing ~= cid then
				table.insert(kept, existing)
			end
		end
		if #kept == 0 then
			pending_waits[pane_id] = nil
			-- If the caller disconnected mid-turn (e.g. `--max-time` or caller turn ended), hand off to auto-callback!
			local still_working = w.saw_working
			if cx then
				local ainfo = find_agent_info(cx, pane_id)
				if ainfo and ainfo.state == "working" then
					still_working = true
				end
			end
			if still_working then
				unsolicited_working[pane_id] = true
			end
		else
			w.cids = kept
		end
	end
	for pane_id, q in pairs(queued_dispatches) do
		local kept: { QueuedDispatch } = {}
		for _, item in ipairs(q) do
			if item.cid ~= cid then
				table.insert(kept, item)
			end
		end
		if #kept == 0 then
			queued_dispatches[pane_id] = nil
		else
			queued_dispatches[pane_id] = kept
		end
	end
end

local function watchdog_step(cx: WindowCx?)
	watchdog_armed = false
	if not has_active_timers() then
		return
	end
	if cx then
		local now = tern.now()
		for pane_id, w in pairs(pending_waits) do
			if w.pending_prompt ~= nil then
				local prompt_text = w.pending_prompt :: string
				if find_agent_info(cx, pane_id) ~= nil then
					local ok_ask = pcall(function()
						cx.agents:ask(pane_id, prompt_text)
					end)
					if ok_ask then
						w.pending_prompt = nil
						if #w.cids == 0 then
							pending_waits[pane_id] = nil
							unsolicited_working[pane_id] = true
							reported_in_turn[pane_id] = false
						end
					end
				end
				if w.pending_prompt ~= nil and w.ask_deadline and now > w.ask_deadline then
					finish_wait(cx, pane_id, "failed", "Timed out waiting for spawned agent TSP surface to accept prompt")
				end
			else
				local ainfo = find_agent_info(cx, pane_id)
				if not ainfo then
					if now - w.started_ms > 5000 and cx.session:pane(pane_id) == nil then
						finish_wait(cx, pane_id, "closed", "Agent pane disappeared")
					end
				else
					local derr: any = ainfo.delivery_error
					if type(derr) == "string" and derr ~= "" then
						finish_wait(cx, pane_id, "failed", "TSP delivery error: " .. derr)
					elseif ainfo.state == "working" then
						w.saw_working = true
						w.idle_since = nil
					elseif ainfo.state == "waiting_input" then
						finish_wait(cx, pane_id, "waiting_input", "Agent is waiting for interactive user input")
					elseif ainfo.state == "exited" then
						finish_wait(cx, pane_id, "exited", "Agent process exited")
					elseif ainfo.state == "idle" and w.saw_working then
						local since = w.idle_since or now
						w.idle_since = since
						if now - since >= 1000 then
							finish_wait(cx, pane_id, "done", nil)
						end
					end
				end
			end
		end

		-- Promote queued dispatches for panes whose active turn wasn't started via `pending_waits`
		for pane_id, _ in pairs(queued_dispatches) do
			if pending_waits[pane_id] == nil then
				local ainfo = find_agent_info(cx, pane_id)
				if not ainfo and cx.session:pane(pane_id) == nil then
					local q = queued_dispatches[pane_id]
					queued_dispatches[pane_id] = nil
					if q then
						for _, item in ipairs(q) do
							if item.cid ~= nil then
								send_mux(item.cid, {
									ok = false,
									pane = pane_id,
									status = "closed",
									error = "Agent pane disappeared",
									last_message = "",
									transcript = tern.json.array(),
								}, false)
							end
						end
					end
				elseif ainfo and ainfo.state == "idle" then
					promote_next_queued(cx, pane_id)
				end
			end
		end

		-- Flush queued owner callbacks once the owner pane becomes idle
		for owner_pane, _ in pairs(queued_callbacks) do
			if pending_waits[owner_pane] == nil and queued_dispatches[owner_pane] == nil then
				flush_queued_callbacks(cx, owner_pane)
			end
		end
	end
	if has_active_timers() and not watchdog_armed then
		watchdog_armed = true
		tern.timer(500, watchdog_step)
	end
end

ensure_watchdog = function()
	if not watchdog_armed and has_active_timers() then
		watchdog_armed = true
		tern.timer(500, watchdog_step)
	end
end

local function seed_inflight_unsolicited_turns(cx: WindowCx)
	prune_bindings(cx)
	for _, a in ipairs(cx.agents:list()) do
		if a.state == "working" and pending_waits[a.pane] == nil and queued_dispatches[a.pane] == nil then
			if owner_of_pane(cx, a.pane) ~= nil then
				unsolicited_working[a.pane] = true
			end
		elseif a.state == "waiting_input" and pending_waits[a.pane] == nil and owner_of_pane(cx, a.pane) ~= nil then
			notify_waiting_input(cx, a.pane)
		elseif a.state == "idle" and pending_waits[a.pane] == nil and owner_of_pane(cx, a.pane) ~= nil then
			if inspect_fault_surface(cx, a.pane) then
				deliver_fault_if_needed(cx, a.pane, nil)
			end
		end
	end
end

-- `working -> idle` without `agent_finished`: wait 1500ms so omp's own internal auto-recovery
-- (`Streaming edit preview failed` attempts 1..2, etc.) finishes undisturbed; escalate ONLY if omp
-- stays stalled in `idle` with an active `F5 to retry` / `omp.error` takeover prompt.
local function settle_stalled_fault(cx: WindowCx, pane: number)
	tern.timer(1500, function(later_cx: WindowCx?)
		local lcx = later_cx or cx
		if manual_interrupt[pane] then
			return
		end
		local ainfo = find_agent_info(lcx, pane)
		if not ainfo or ainfo.state ~= "idle" or pending_waits[pane] ~= nil then
			return
		end
		if inspect_fault_surface(lcx, pane) then
			unsolicited_working[pane] = false
			reported_in_turn[pane] = false
			deliver_fault_if_needed(lcx, pane, nil)
		end
	end)
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	if ev.new == "working" then
		manual_interrupt[ev.pane] = nil
		clear_waiting(ev.pane)
	elseif ev.new ~= "waiting_input" and not string.find(notified_waiting[ev.pane] or "", "^fault:") then
		clear_waiting(ev.pane)
	end
	local w = pending_waits[ev.pane]
	if w then
		if w.pending_prompt ~= nil then
			local prompt_text = w.pending_prompt :: string
			local ok_ask = pcall(function()
				cx.agents:ask(ev.pane, prompt_text)
			end)
			if ok_ask then
				w.pending_prompt = nil
				if #w.cids == 0 then
					pending_waits[ev.pane] = nil
					unsolicited_working[ev.pane] = true
					reported_in_turn[ev.pane] = false
				end
			end
			return
		end
		if ev.new == "working" then
			w.saw_working = true
			w.idle_since = nil
		elseif ev.new == "waiting_input" then
			finish_wait(cx, ev.pane, "waiting_input", "Agent is waiting for interactive user input")
		elseif ev.new == "exited" then
			finish_wait(cx, ev.pane, "exited", "Agent process exited")
		end
		return
	end

	-- Track unsolicited turns on bound wingman panes (e.g. omp background job starting a new turn)
	if ev.new == "waiting_input" then
		if owner_of_pane(cx, ev.pane) ~= nil then
			notify_waiting_input(cx, ev.pane)
		end
	elseif ev.old == "waiting_input" and ev.new == "working" and owner_of_pane(cx, ev.pane) ~= nil then
		unsolicited_working[ev.pane] = true
	elseif ev.new == "working" and ev.old ~= "working" and queued_dispatches[ev.pane] == nil then
		if owner_of_pane(cx, ev.pane) ~= nil then
			unsolicited_working[ev.pane] = true
			reported_in_turn[ev.pane] = false
		end
	elseif ev.old == "working" and ev.new == "idle" and owner_of_pane(cx, ev.pane) ~= nil then
		settle_stalled_fault(cx, ev.pane)
	end
	if ev.new == "idle" and queued_callbacks[ev.pane] ~= nil and queued_dispatches[ev.pane] == nil then
		flush_queued_callbacks(cx, ev.pane)
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	if ev.result == "done" then
		clear_waiting(ev.pane)
	end
	-- 1. If this pane is an owner with pending wingman callbacks, flush them as soon as its turn finishes cleanly
	if queued_callbacks[ev.pane] ~= nil and ev.result == "done" and queued_dispatches[ev.pane] == nil then
		flush_queued_callbacks(cx, ev.pane)
	end

	-- 2. Active synchronous/async `send` or `await` waiter gets direct reply over mux socket
	local w = pending_waits[ev.pane]
	if w then
		if w.pending_prompt ~= nil then
			return
		end
		finish_wait(cx, ev.pane, ev.result, nil)
		return
	end

	-- 3. If the completed turn was an async/unsolicited turn, push its completion to `owner` FIRST (before promoting next queued item!)
	local was_unsolicited = unsolicited_working[ev.pane] == true
	if (ev.result == "failed" or ev.result == "exited") and not manual_interrupt[ev.pane] and owner_of_pane(cx, ev.pane) ~= nil then
		-- Failed/exited turns (including across plugin reload) report the native error surface + retry hint once TSP settles.
		unsolicited_working[ev.pane] = false
		reported_in_turn[ev.pane] = false
		was_unsolicited = false
		local failed_pane = ev.pane
		local failed_res = ev.result
		tern.timer(150, function(later_cx: WindowCx?)
			local lcx = later_cx or cx
			if not manual_interrupt[failed_pane] then
				deliver_fault_if_needed(lcx, failed_pane, "Agent turn ended with " .. failed_res)
			end
		end)
	end
	if was_unsolicited then
		unsolicited_working[ev.pane] = false
		local already_reported = reported_in_turn[ev.pane] == true
		reported_in_turn[ev.pane] = false
		local owner = owner_of_pane(cx, ev.pane)
		local has_next_q = queued_dispatches[ev.pane] ~= nil and #queued_dispatches[ev.pane] > 0 and ev.result == "done"
		if
			owner ~= nil
			and not already_reported
			and is_auto_callback_enabled(owner)
			and (ev.result == "done" or ev.result == "failed" or ev.result == "exited")
		then
			local last_msg, _ = collect_turn_output(cx, ev.pane)
			local body = if last_msg and last_msg ~= ""
				then last_msg
				else string.format("(Wingman turn finished with status: %s)", ev.result)
			local tag = if has_next_q
				then string.format("auto-callback · %s · promoting next queued task", ev.result)
				else ("auto-callback · " .. ev.result)
			deliver_to_owner(cx, owner, ev.pane, tag, body)
		end
	end

	-- 4. Queued `send` dispatches promote in FIFO order
	if queued_dispatches[ev.pane] then
		if ev.result == "done" then
			promote_next_queued(cx, ev.pane)
		else
			local q = queued_dispatches[ev.pane]
			queued_dispatches[ev.pane] = nil
			if q then
				for _, item in ipairs(q) do
					if item.cid ~= nil then
						send_mux(item.cid, {
							ok = false,
							pane = ev.pane,
							status = ev.result,
							error = "Previous turn ended with " .. ev.result,
							last_message = "",
							transcript = tern.json.array(),
						}, false)
					end
				end
			end
		end
		return
	end

	-- 5. If the worker stayed continuously `working` (e.g. an omp background job will trigger another turn without dipping to `idle`), keep tracking
	if was_unsolicited then
		local finished_pane = ev.pane
		tern.timer(250, function(later_cx: WindowCx?)
			if not later_cx then
				return
			end
			if pending_waits[finished_pane] == nil and queued_dispatches[finished_pane] == nil then
				local ainfo = find_agent_info(later_cx, finished_pane)
				if ainfo and ainfo.state == "working" and owner_of_pane(later_cx, finished_pane) ~= nil then
					unsolicited_working[finished_pane] = true
				end
			end
		end)
	end
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	unbind_pane(ev.pane)
	clear_waiting(ev.pane)
	unsolicited_working[ev.pane] = nil
	reported_in_turn[ev.pane] = nil
	queued_callbacks[ev.pane] = nil
	if pending_waits[ev.pane] then
		finish_wait(cx, ev.pane, "closed", "Agent pane was closed")
	elseif queued_dispatches[ev.pane] then
		local q = queued_dispatches[ev.pane]
		queued_dispatches[ev.pane] = nil
		if q then
			for _, item in ipairs(q) do
				if item.cid ~= nil then
					send_mux(item.cid, {
						ok = false,
						pane = ev.pane,
						status = "closed",
						error = "Agent pane was closed",
						last_message = "",
						transcript = tern.json.array(),
					}, false)
				end
			end
		end
	end
end)

local function register_waiter(pane_id: number, cid: number?, pending_prompt: string?)
	unsolicited_working[pane_id] = false
	reported_in_turn[pane_id] = false
	local existing = pending_waits[pane_id]
	if existing then
		if cid ~= nil then
			table.insert(existing.cids, cid)
		end
		if pending_prompt ~= nil then
			existing.pending_prompt = pending_prompt
			existing.ask_deadline = tern.now() + 20000
		end
	else
		local cids_list: { number } = {}
		if cid ~= nil then
			table.insert(cids_list, cid)
		end
		pending_waits[pane_id] = {
			cids = cids_list,
			started_ms = tern.now(),
			saw_working = false,
			idle_since = nil,
			pending_prompt = pending_prompt,
			ask_deadline = if pending_prompt ~= nil then (tern.now() + 20000) else nil,
		}
	end
	ensure_watchdog()
end

local function resolve_report_owner(cx: WindowCx, worker_pane: number, explicit_target: number?): (number?, string?)
	if explicit_target ~= nil then
		if explicit_target == worker_pane then
			return nil, "refusing to report onto caller's own pane"
		end
		if cx.session:pane(explicit_target) == nil then
			return nil, "explicit owner pane does not exist in this session"
		end
		return explicit_target, nil
	end
	local bound_owner = owner_of_pane(cx, worker_pane)
	if bound_owner ~= nil then
		return bound_owner, nil
	end
	-- Fallback when user opened supervisor + wingman manually in the same tab without `wingman.py send` yet:
	local my_tab = cx.session:tab_of(worker_pane)
	if my_tab ~= nil then
		local peers: { number } = {}
		for _, a in ipairs(cx.agents:list()) do
			if a.pane ~= worker_pane and cx.session:tab_of(a.pane) == my_tab then
				table.insert(peers, a.pane)
			end
		end
		if #peers == 1 then
			return peers[1], nil
		end
	end
	return nil, "no supervisor/owner pane is bound to this wingman pane (pass `--pane <id>` to specify)"
end

local function handle_request(cx: WindowCx, cid: number, req: any)
	local op = req.op
	local anchor = tonumber(req.anchor_pane)

	if op == "status" then
		seed_inflight_unsolicited_turns(cx)
		local my_tab = if anchor then cx.session:tab_of(anchor) else nil
		local bound_pane = if anchor then get_bound_wingman(cx, anchor) else nil
		local my_owner = if anchor then owner_of_pane(cx, anchor) else nil
		local floats = tern.json.array()
		if my_tab then
			local lay = cx.session:layout(my_tab)
			if lay and lay.floats then
				floats = tern.json.array(lay.floats)
			end
		end
		local out = {}
		for _, a in ipairs(cx.agents:list()) do
			local atab = cx.session:tab_of(a.pane)
			local owner = owner_of_pane(cx, a.pane)
			local q = queued_dispatches[a.pane]
			local q_count = if q then #q else 0
			local q_preview: string? = nil
			if q and #q > 0 then
				q_preview = string.sub(q[1].prompt, 1, 120)
			end
			local cb_q = queued_callbacks[a.pane]
			local cb_q_count = if cb_q then #cb_q else 0
			table.insert(out, {
				pane = a.pane,
				tab = atab,
				same_tab = (my_tab ~= nil and atab == my_tab),
				is_self = (anchor ~= nil and a.pane == anchor),
				is_bound_to_me = (bound_pane ~= nil and a.pane == bound_pane),
				bound_owner = owner,
				auto_callback = if owner ~= nil then is_auto_callback_enabled(owner) else is_auto_callback_enabled(a.pane),
				queued_count = q_count,
				queued_preview = q_preview,
				queued_callbacks_count = cb_q_count,
				cwd = a.cwd,
				state = a.state,
				model = if a.model ~= tern.json.null then a.model else nil,
				command = if a.command ~= tern.json.null then a.command else nil,
				last_message = if a.last_message ~= tern.json.null then a.last_message else nil,
				delivery_error = if a.delivery_error ~= tern.json.null then a.delivery_error else nil,
			})
		end
		send_mux(cid, {
			ok = true,
			window_key = cx:window_key(),
			anchor_tab = my_tab,
			bound_pane = bound_pane,
			owner_pane = my_owner,
			auto_callback = is_auto_callback_enabled(anchor),
			default_auto_callback = default_auto_callback,
			agents = tern.json.array(out),
			floats = floats,
		}, false)
		return
	end

	if op == "report" then
		if not anchor then
			send_mux(cid, { ok = false, error = "missing anchor_pane" }, false)
			return
		end
		local prompt = tostring(req.prompt or "")
		if prompt == "" then
			send_mux(cid, { ok = false, error = "report message is empty" }, false)
			return
		end
		local explicit_target: number? = if req.target_pane ~= nil and req.target_pane ~= tern.json.null
			then tonumber(req.target_pane)
			else nil
		local owner, err_owner = resolve_report_owner(cx, anchor, explicit_target)
		if not owner then
			send_mux(cid, { ok = false, error = err_owner or "no owner pane found" }, false)
			return
		end
		local kind = tostring(req.kind or "final")
		if kind ~= "progress" then
			reported_in_turn[anchor] = true
		end
		local tag = if kind == "progress"
			then "progress"
			elseif kind == "question" then "question"
			else "report"
		local delivered, queued, pos = deliver_to_owner(cx, owner, anchor, tag, prompt)
		send_mux(cid, {
			ok = true,
			worker_pane = anchor,
			owner_pane = owner,
			kind = kind,
			delivered = delivered,
			queued = queued,
			position = pos,
		}, false)
		return
	end

	if op == "callback" then
		local mode = tostring(req.mode or "status")
		local scope = tostring(req.scope or "owner")
		local target_owner: number? = if req.owner_pane ~= nil and req.owner_pane ~= tern.json.null
			then tonumber(req.owner_pane)
			else anchor
		if target_owner ~= nil and bindings[target_owner] == nil then
			local maybe_owner = owner_of_pane(cx, target_owner)
			if maybe_owner ~= nil then
				target_owner = maybe_owner
			end
		end
		if mode == "on" or mode == "off" then
			local val = (mode == "on")
			if scope == "global" or target_owner == nil then
				default_auto_callback = val
			else
				owner_auto_callback[target_owner] = val
			end
			save_callback_cfg()
		elseif mode == "reset" then
			if scope == "global" then
				default_auto_callback = true
				owner_auto_callback = {}
			elseif target_owner ~= nil then
				owner_auto_callback[target_owner] = nil
			end
			save_callback_cfg()
		end
		send_mux(cid, {
			ok = true,
			owner_pane = target_owner,
			enabled = is_auto_callback_enabled(target_owner),
			default_enabled = default_auto_callback,
		}, false)
		return
	end

	if op == "pip" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to float anchor_pane (caller agent itself)" }, false)
			return
		end
		if anchor then
			bind_wingman(anchor, tp)
		end
		local ok_f, err_f = cx.layout:float(tp, anchor, req.corner or "br", { focus = false })
		send_mux(cid, { ok = ok_f, error = err_f }, false)
		return
	end

	if op == "dock" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to dock anchor_pane (caller agent itself)" }, false)
			return
		end
		if anchor then
			bind_wingman(anchor, tp)
		end
		local ok_d, err_d = cx.layout:dock(tp, anchor, req.dir or "right", { focus = false })
		send_mux(cid, { ok = ok_d, error = err_d }, false)
		return
	end

	if op == "interrupt" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to interrupt anchor_pane (caller agent itself)" }, false)
			return
		end
		manual_interrupt[tp] = true
		unsolicited_working[tp] = false
		local ok_i, err_i = pcall(function()
			cx.agents:interrupt(tp)
		end)
		send_mux(cid, { ok = ok_i, error = if not ok_i then tostring(err_i) else nil }, false)
		return
	end

	if op == "unqueue" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to unqueue anchor_pane (caller agent itself)" }, false)
			return
		end
		local q = queued_dispatches[tp]
		if not q or #q == 0 then
			send_mux(cid, { ok = true, pane = tp, cancelled = 0, remaining = 0 }, false)
			return
		end
		local pos = if req.position ~= nil and req.position ~= tern.json.null then tonumber(req.position) else nil
		local cancelled = 0
		if pos then
			local idx = math.floor(pos)
			if idx < 1 or idx > #q then
				send_mux(cid, { ok = false, error = string.format("queue position %d out of range (1..%d)", idx, #q) }, false)
				return
			end
			local removed = table.remove(q, idx) :: QueuedDispatch
			cancelled = 1
			if removed.cid ~= nil then
				send_mux(removed.cid, {
					ok = false,
					pane = tp,
					status = "cancelled",
					error = "Cancelled from queue via unqueue",
					last_message = "",
					transcript = tern.json.array(),
				}, false)
			end
			if #q == 0 then
				queued_dispatches[tp] = nil
			end
		else
			queued_dispatches[tp] = nil
			for _, item in ipairs(q) do
				cancelled += 1
				if item.cid ~= nil then
					send_mux(item.cid, {
						ok = false,
						pane = tp,
						status = "cancelled",
						error = "Cancelled from queue via unqueue",
						last_message = "",
						transcript = tern.json.array(),
					}, false)
				end
			end
		end
		local rem = if queued_dispatches[tp] then #queued_dispatches[tp] else 0
		send_mux(cid, { ok = true, pane = tp, cancelled = cancelled, remaining = rem }, false)
		return
	end

	if op == "retry" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to retry anchor_pane (caller agent itself)" }, false)
			return
		end
		local ainfo = find_agent_info(cx, tp)
		if ainfo and (ainfo.state == "working" or ainfo.state == "waiting_input") then
			send_mux(cid, { ok = false, pane = tp, state = ainfo.state, error = "target pane is " .. ainfo.state .. " (not idle/failed)" }, false)
			return
		end
		local ok_r, err_r = pcall(function()
			cx.agents:ask(tp, "/retry")
		end)
		if not ok_r then
			send_mux(cid, { ok = false, pane = tp, error = "cx.agents:ask /retry failed: " .. tostring(err_r) }, false)
			return
		end
		clear_waiting(tp)
		manual_interrupt[tp] = nil
		if anchor then
			bind_wingman(anchor, tp)
		end
		if req.async_callback == true then
			if anchor and owner_auto_callback[anchor] == false then
				owner_auto_callback[anchor] = true
				save_callback_cfg()
			end
			unsolicited_working[tp] = true
			reported_in_turn[tp] = false
			send_mux(cid, { ok = true, async_callback = true, pane = tp, retried = true }, false)
		else
			send_mux(cid, { _ack = true, pane = tp }, true)
			register_waiter(tp, cid, nil)
		end
		return
	end

	if op == "stop" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to stop anchor_pane (caller agent itself)" }, false)
			return
		end
		unbind_pane(tp)
		clear_waiting(tp)
		unsolicited_working[tp] = nil
		reported_in_turn[tp] = nil
		local ok_s, err_s = pcall(function()
			cx.agents:stop(tp)
		end)
		send_mux(cid, { ok = ok_s, error = if not ok_s then tostring(err_s) else nil }, false)
		return
	end

	if op == "transcript" then
		local tp = tonumber(req.target_pane) :: number
		local ok_t, msgs = pcall(function()
			return cx.agents:transcript(tp, { last = tonumber(req.last) or 10 })
		end)
		if not ok_t then
			send_mux(cid, { ok = false, error = tostring(msgs) }, false)
		else
			send_mux(cid, { ok = true, messages = tern.json.array(msgs) }, false)
		end
		return
	end

	if op == "surface" then
		local tp = tonumber(req.target_pane) :: number
		local root: any = if req.root ~= tern.json.null then req.root else nil
		local auto_root = req.auto_root == true
		local want_as = req.as or "text"
		local i_root, i_role = nil, nil
		local ok_tree, tree = pcall(function()
			return cx.session:surface(tp, {
				as = "table",
				root = if not auto_root then root else nil,
				depth = req.depth,
				nodes = req.nodes or 1500,
			})
		end)
		if not ok_tree then
			send_mux(cid, { ok = false, pane = tp, error = tostring(tree) }, false)
			return
		end
		if auto_root and type(tree) == "table" then
			i_root, i_role = find_interactive_root(tree)
			if root == nil then
				root = i_root
			end
		end
		if want_as == "table" then
			local out_tree = tree
			if root ~= nil and type(tree) == "table" then
				local sub = find_node_by_id(tree, tostring(root))
				if sub ~= nil then
					out_tree = sub
				end
			end
			send_mux(cid, { ok = true, pane = tp, root = root, interactive_root = i_root, interactive_role = i_role, surface = out_tree }, false)
			return
		end
		local lines: { string } = {}
		if type(tree) == "table" then
			if root ~= nil then
				local sub = find_node_by_id(tree, tostring(root))
				if sub ~= nil then
					format_tsp_subtree(sub, "", lines, 0)
				end
			else
				for _, region in ipairs({ "layer", "main", "dock" }) do
					if type(tree[region]) == "table" then
						format_tsp_subtree(tree[region], "", lines, 0)
					end
				end
			end
		end
		send_mux(cid, {
			ok = true,
			pane = tp,
			root = root,
			interactive_root = i_root,
			interactive_role = i_role,
			surface = table.concat(lines, "\n"),
		}, false)
		return
	end

	if op == "event" then
		local tp = tonumber(req.target_pane)
		if not tp or (anchor and tp == anchor) then
			send_mux(cid, { ok = false, error = "invalid target_pane for event (refusing caller's own pane)" }, false)
			return
		end
		local events: any = if type(req.events) == "table" then req.events elseif type(req.ev) == "table" then { req.ev } else {}
		local results = {}
		local all_ok = #events > 0
		for i, ev in ipairs(events) do
			local ok_e, res_e = pcall(function()
				return cx.session:event(tp :: number, ev)
			end)
			all_ok = all_ok and ok_e
			table.insert(results, { index = i, ok = ok_e, error = if ok_e then nil else tostring(res_e), result = if ok_e then res_e else nil })
		end
		if req.rearm ~= false then
			clear_waiting(tp)
			if anchor then
				bind_wingman(anchor, tp)
			end
			unsolicited_working[tp] = true
			reported_in_turn[tp] = false
		end
		send_mux(cid, {
			ok = all_ok,
			pane = tp,
			error = if #events == 0 then "no events given" else nil,
			results = tern.json.array(results),
		}, false)
		return
	end

	if op == "await" then
		local tp = tonumber(req.target_pane)
		if not tp or (anchor and tp == anchor) then
			send_mux(cid, { ok = false, error = "invalid target_pane for await" }, false)
			return
		end
		if anchor then
			bind_wingman(anchor, tp)
		end
		send_mux(cid, { _ack = true, pane = tp }, true)
		local ainfo = find_agent_info(cx, tp)
		if not ainfo then
			if cx.session:pane(tp) == nil then
				send_mux(cid, { ok = false, pane = tp, status = "closed", error = "Agent pane disappeared", last_message = "", transcript = tern.json.array() }, false)
				return
			end
			register_waiter(tp, cid, nil)
			return
		end
		local derr: any = ainfo.delivery_error
		if type(derr) == "string" and derr ~= "" then
			local last_msg, transcript = collect_turn_output(cx, tp)
			send_mux(cid, { ok = false, pane = tp, status = "failed", error = "TSP delivery error: " .. derr, last_message = last_msg or "", transcript = transcript }, false)
			return
		end
		if ainfo.state == "idle" then
			local last_msg, transcript = collect_turn_output(cx, tp)
			send_mux(cid, { ok = true, pane = tp, status = "done", last_message = last_msg or "", transcript = transcript }, false)
			return
		end
		if ainfo.state == "waiting_input" or ainfo.state == "exited" then
			local last_msg, transcript = collect_turn_output(cx, tp)
			local reason = if ainfo.state == "waiting_input" then "Agent is waiting for interactive user input" else "Agent process exited"
			send_mux(cid, { ok = false, pane = tp, status = ainfo.state, error = reason, last_message = last_msg or "", transcript = transcript }, false)
			return
		end
		register_waiter(tp, cid, nil)
		local w = pending_waits[tp]
		if w then
			w.saw_working = true
		end
		return
	end

	if op == "dispatch" then
		if not anchor then
			send_mux(cid, { ok = false, error = "missing anchor_pane" }, false)
			return
		end
		local prompt = tostring(req.prompt or "")
		local cwd = tostring(req.cwd or "")
		local cmd = req.command
		local target_pane: number? = if req.target_pane ~= nil and req.target_pane ~= tern.json.null then tonumber(req.target_pane) else nil
		local reset_new = req.reset_new == true
		local pip_corner = req.pip_corner
		local async_cb = req.async_callback == true

		if async_cb then
			-- Async ACP callback mode requires auto-callback to be active on `anchor` so completion returns via `cx.agents:ask`
			if owner_auto_callback[anchor] == false then
				owner_auto_callback[anchor] = true
				save_callback_cfg()
			end
		elseif type(req.auto_callback) == "boolean" then
			owner_auto_callback[anchor] = req.auto_callback
			save_callback_cfg()
		end

		if target_pane and target_pane == anchor then
			send_mux(cid, { ok = false, error = "refusing to dispatch onto anchor_pane (caller agent itself)" }, false)
			return
		end

		if target_pane and reset_new then
			unbind_pane(target_pane)
			unsolicited_working[target_pane] = nil
			reported_in_turn[target_pane] = nil
			clear_waiting(target_pane :: number)
			pcall(function()
				cx.agents:stop(target_pane :: number)
			end)
			target_pane = nil
		end

		local pending_bootstrap_prompt: string? = nil

		if target_pane then
			local ainfo = find_agent_info(cx, target_pane)
			if ainfo and ainfo.state == "waiting_input" then
				send_mux(cid, {
					ok = false,
					status = "waiting_input",
					pane = target_pane,
					error = "target wingman pane is waiting_input; inspect via `wingman.py surface` and answer/cancel via `wingman.py event` instead of `send`",
				}, false)
				return
			end
			if ainfo and ainfo.state == "working" then
				if req.queue == false then
					send_mux(cid, { ok = false, error = "target agent pane is currently busy (working)" }, false)
					return
				end
				bind_wingman(anchor, target_pane)
				local q = queued_dispatches[target_pane]
				if not q then
					q = {}
					queued_dispatches[target_pane] = q
				end
				local corner_str: string? = if type(pip_corner) == "string" and pip_corner ~= "" then pip_corner else nil
				table.insert(q, {
					cid = if async_cb then nil else cid,
					anchor = anchor,
					prompt = prompt,
					pip_corner = corner_str,
				})
				if async_cb then
					send_mux(cid, { ok = true, async_callback = true, pane = target_pane, queued = true, position = #q }, false)
				else
					send_mux(cid, { _ack = true, pane = target_pane, queued = true, position = #q }, true)
				end
				ensure_watchdog()
				return
			end
			local ok_ask, err_ask = pcall(function()
				cx.agents:ask(target_pane :: number, prompt)
			end)
			if not ok_ask then
				send_mux(cid, { ok = false, error = "cx.agents:ask failed: " .. tostring(err_ask) }, false)
				return
			end
		else
			local focused_now = cx.session:focused()
			if focused_now == anchor then
				local ok_st, res_st = pcall(function()
					return cx.agents:start({
						prompt = prompt,
						cwd = cwd,
						command = cmd,
						how = "split",
					})
				end)
				if not ok_st then
					send_mux(cid, { ok = false, error = "cx.agents:start failed: " .. tostring(res_st) }, false)
					return
				end
				target_pane = res_st
				cx.layout:focus(anchor)
			else
				-- User is focused elsewhere: split anchor silently without stealing focus, then submit via TSP once agent_state fires
				local new_p = cx.layout:split(anchor, "right", { cwd = cwd, command = cmd }, { focus = false })
				if not new_p then
					send_mux(cid, { ok = false, error = "cx.layout:split returned nil" }, false)
					return
				end
				target_pane = new_p
				pending_bootstrap_prompt = prompt
			end
		end

		local final_pane = target_pane :: number
		bind_wingman(anchor, final_pane)

		if pip_corner and pip_corner ~= tern.json.null then
			pcall(function()
				cx.layout:float(final_pane, anchor, pip_corner, { focus = false })
			end)
		end

		if async_cb then
			if pending_bootstrap_prompt ~= nil then
				register_waiter(final_pane, nil, pending_bootstrap_prompt)
			else
				unsolicited_working[final_pane] = true
				reported_in_turn[final_pane] = false
			end
			send_mux(cid, { ok = true, async_callback = true, pane = final_pane, queued = false, position = 0 }, false)
			return
		end

		send_mux(cid, { _ack = true, pane = final_pane }, true)
		register_waiter(final_pane, cid, pending_bootstrap_prompt)
		return
	end

	send_mux(cid, { ok = false, error = "unknown op: " .. tostring(op) }, false)
end

local ensure_mux: () -> ()
local mux_saw_ready = false
local win_py_launcher_idx = 1

local function build_mux_argv(mux_script: string): { string }
	if not is_windows then
		return { "python3", "-u", mux_script, ipc_dir }
	end
	if win_py_launcher_idx == 1 then
		return { "python", "-u", mux_script, ipc_dir }
	elseif win_py_launcher_idx == 2 then
		return { "py", "-3", "-u", mux_script, ipc_dir }
	end
	return { "python3", "-u", mux_script, ipc_dir }
end

local function on_mux_stdout(line: string, cx: WindowCx?)
	if line == "" then
		return
	end
	local ok_j, msg = pcall(tern.json.decode, line)
	if not ok_j or type(msg) ~= "table" then
		return
	end
	if msg.type == "ready" then
		mux_saw_ready = true
		return
	end
	local cid = tonumber(msg.id)
	if not cid then
		return
	end
	if msg.disconnected == true then
		drop_disconnected_cid(cid, cx)
		return
	end
	local req = msg.req
	if type(req) ~= "table" then
		send_mux(cid, { ok = false, error = "malformed mux request" }, false)
		return
	end
	if not cx then
		send_mux(cid, { _skip = true }, false)
		return
	end
	if not same_daemon(req.daemon_socket) then
		send_mux(cid, { _skip = true }, false)
		return
	end
	local anchor = tonumber(req.anchor_pane)
	if anchor ~= nil and cx.session:pane(anchor) == nil then
		send_mux(cid, { _skip = true }, false)
		return
	end
	local ok_h, err_h = pcall(handle_request, cx, cid, req)
	if not ok_h then
		send_mux(cid, { ok = false, error = tostring(err_h) }, false)
	end
end

ensure_mux = function()
	if unloading or mux_child ~= nil then
		return
	end
	local mux_script = tern.plugin.dir .. SEP .. "mux.py"
	mux_saw_ready = false
	local argv = build_mux_argv(mux_script)
	local ok_sp, child_or_err = pcall(function()
		return tern.process.spawn(argv, {
			split = "lines",
			stdout = on_mux_stdout,
			exit = function(_res: SpawnExit, _cx: WindowCx?)
				mux_child = nil
				if is_windows and not mux_saw_ready then
					win_py_launcher_idx = (win_py_launcher_idx % 3) + 1
				end
				if not unloading then
					tern.timer(500, function(_later: WindowCx?)
						ensure_mux()
					end)
				end
			end,
		})
	end)
	if ok_sp then
		mux_child = child_or_err
	else
		if is_windows then
			win_py_launcher_idx = (win_py_launcher_idx % 3) + 1
		end
		tern.log.error("wingman: failed to spawn mux.py:", tostring(child_or_err))
		if not unloading then
			tern.timer(2000, function(_later: WindowCx?)
				ensure_mux()
			end)
		end
	end
end

tern.command({
	id = "toggle_auto_callback",
	title = "Wingman: Toggle auto-callback to supervisor",
	icon = "bell",
	run = function(cx: WindowCx)
		default_auto_callback = not default_auto_callback
		save_callback_cfg()
		local state_label = if default_auto_callback then "enabled" else "disabled"
		cx:toast("info", "Wingman auto-callback " .. state_label, "Unsolicited worker turns push to bound supervisor when enabled.")
	end,
})

tern.on("unload", function()
	unloading = true
	local child = mux_child
	mux_child = nil
	if child then
		pcall(function()
			child:kill("terminate")
		end)
	end
end)

local started = false
local function start(cx: WindowCx?)
	if not started then
		started = true
		load_bindings()
		load_callback_cfg()
		load_waiting()
		ensure_mux()
	end
	if cx then
		seed_inflight_unsolicited_turns(cx)
	end
end

tern.on("window_start", start)
tern.timer(0, start)
