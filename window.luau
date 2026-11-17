--!strict
-- Wingman: Event-driven WindowCx.agents TSP bridge & ownership graph for coding agents in Tern.

local runtime_dir = tern.getenv("XDG_RUNTIME_DIR")
local home_dir = tern.getenv("HOME")
local daemon_socket = tern.getenv("TERN_DAEMON_SOCKET") or tern.getenv("TERN_PANE_SOCKET")

local function resolve_ipc_dir(): string
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

type WaitEntry = {
	cids: { number },
	started_ms: number,
	saw_working: boolean,
	idle_since: number?,
	pending_prompt: string?,
	ask_deadline: number?,
}

type QueuedDispatch = {
	cid: number,
	anchor: number,
	prompt: string,
	pip_corner: string?,
}

-- Explicit ownership bijection: anchor_pane -> wingman_pane
local bindings: { [number]: number } = {}
-- Active in-flight turn waits keyed by wingman pane_id
local pending_waits: { [number]: WaitEntry } = {}
-- Native per-pane FIFO dispatch queue when target_pane is busy (`working`)
local queued_dispatches: { [number]: { QueuedDispatch } } = {}

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
end

local function same_daemon(req_socket: any): boolean
	if req_socket == nil or req_socket == tern.json.null or req_socket == "" then
		return true
	end
	if daemon_socket and daemon_socket ~= "" then
		return req_socket == daemon_socket
	end
	return type(req_socket) == "string" and string.sub(req_socket, -12) == "/daemon.sock"
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
	return last_msg, transcript
end

local ensure_watchdog: () -> ()

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
		send_mux(item.cid, {
			ok = false,
			pane = pane_id,
			status = "failed",
			error = "queued cx.agents:ask failed: " .. tostring(err_ask),
			last_message = "",
			transcript = tern.json.array(),
		}, false)
		promote_next_queued(cx, pane_id)
		return
	end

	bind_wingman(item.anchor, pane_id)
	if item.pip_corner and item.pip_corner ~= "" then
		pcall(function()
			cx.layout:float(pane_id, item.anchor, item.pip_corner, { focus = false })
		end)
	end
	pending_waits[pane_id] = {
		cids = { item.cid },
		started_ms = tern.now(),
		saw_working = false,
		idle_since = nil,
		pending_prompt = nil,
		ask_deadline = nil,
	}
	ensure_watchdog()
end

local function finish_wait(cx: WindowCx, pane_id: number, status: string, err_msg: string?)
	local w = pending_waits[pane_id]
	if not w then
		return
	end
	pending_waits[pane_id] = nil
	local last_msg, transcript = collect_turn_output(cx, pane_id)
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
	if status == "done" or status == "idle" then
		promote_next_queued(cx, pane_id)
	else
		local q = queued_dispatches[pane_id]
		if q then
			queued_dispatches[pane_id] = nil
			for _, item in ipairs(q) do
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

local function drop_disconnected_cid(cid: number)
	for pane_id, w in pairs(pending_waits) do
		local kept = {}
		for _, existing in ipairs(w.cids) do
			if existing ~= cid then
				table.insert(kept, existing)
			end
		end
		if #kept == 0 then
			pending_waits[pane_id] = nil
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
	if next(pending_waits) == nil and next(queued_dispatches) == nil then
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

		-- Also promote queued dispatches for panes whose active turn wasn't started via `pending_waits`
		for pane_id, _ in pairs(queued_dispatches) do
			if pending_waits[pane_id] == nil then
				local ainfo = find_agent_info(cx, pane_id)
				if not ainfo and cx.session:pane(pane_id) == nil then
					local q = queued_dispatches[pane_id]
					queued_dispatches[pane_id] = nil
					if q then
						for _, item in ipairs(q) do
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
				elseif ainfo and ainfo.state == "idle" then
					promote_next_queued(cx, pane_id)
				end
			end
		end
	end
	if (next(pending_waits) ~= nil or next(queued_dispatches) ~= nil) and not watchdog_armed then
		watchdog_armed = true
		tern.timer(500, watchdog_step)
	end
end

ensure_watchdog = function()
	if not watchdog_armed and (next(pending_waits) ~= nil or next(queued_dispatches) ~= nil) then
		watchdog_armed = true
		tern.timer(500, watchdog_step)
	end
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	local w = pending_waits[ev.pane]
	if not w then
		return
	end
	if w.pending_prompt ~= nil then
		local prompt_text = w.pending_prompt :: string
		local ok_ask = pcall(function()
			cx.agents:ask(ev.pane, prompt_text)
		end)
		if ok_ask then
			w.pending_prompt = nil
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
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	local w = pending_waits[ev.pane]
	if w then
		if w.pending_prompt ~= nil then
			return
		end
		finish_wait(cx, ev.pane, ev.result, nil)
		return
	end
	if queued_dispatches[ev.pane] then
		if ev.result == "done" then
			promote_next_queued(cx, ev.pane)
		else
			local q = queued_dispatches[ev.pane]
			queued_dispatches[ev.pane] = nil
			if q then
				for _, item in ipairs(q) do
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
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	unbind_pane(ev.pane)
	if pending_waits[ev.pane] then
		finish_wait(cx, ev.pane, "closed", "Agent pane was closed")
	elseif queued_dispatches[ev.pane] then
		local q = queued_dispatches[ev.pane]
		queued_dispatches[ev.pane] = nil
		if q then
			for _, item in ipairs(q) do
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
end)

local function register_waiter(pane_id: number, cid: number, pending_prompt: string?)
	local existing = pending_waits[pane_id]
	if existing then
		table.insert(existing.cids, cid)
		if pending_prompt ~= nil then
			existing.pending_prompt = pending_prompt
			existing.ask_deadline = tern.now() + 20000
		end
	else
		pending_waits[pane_id] = {
			cids = { cid },
			started_ms = tern.now(),
			saw_working = false,
			idle_since = nil,
			pending_prompt = pending_prompt,
			ask_deadline = if pending_prompt ~= nil then (tern.now() + 20000) else nil,
		}
	end
	ensure_watchdog()
end

local function handle_request(cx: WindowCx, cid: number, req: any)
	local op = req.op
	local anchor = tonumber(req.anchor_pane)

	if op == "status" then
		local my_tab = if anchor then cx.session:tab_of(anchor) else nil
		local bound_pane = if anchor then get_bound_wingman(cx, anchor) else nil
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
			table.insert(out, {
				pane = a.pane,
				tab = atab,
				same_tab = (my_tab ~= nil and atab == my_tab),
				is_self = (anchor ~= nil and a.pane == anchor),
				is_bound_to_me = (bound_pane ~= nil and a.pane == bound_pane),
				bound_owner = owner,
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
			agents = tern.json.array(out),
			floats = floats,
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
		local ok_i, err_i = pcall(function()
			cx.agents:interrupt(tp)
		end)
		send_mux(cid, { ok = ok_i, error = if not ok_i then tostring(err_i) else nil }, false)
		return
	end

	if op == "stop" then
		local tp = tonumber(req.target_pane) :: number
		if anchor and tp == anchor then
			send_mux(cid, { ok = false, error = "refusing to stop anchor_pane (caller agent itself)" }, false)
			return
		end
		unbind_pane(tp)
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

		if target_pane and target_pane == anchor then
			send_mux(cid, { ok = false, error = "refusing to dispatch onto anchor_pane (caller agent itself)" }, false)
			return
		end

		if target_pane and reset_new then
			unbind_pane(target_pane)
			pcall(function()
				cx.agents:stop(target_pane :: number)
			end)
			target_pane = nil
		end

		local pending_bootstrap_prompt: string? = nil

		if target_pane then
			local ainfo = find_agent_info(cx, target_pane)
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
					cid = cid,
					anchor = anchor,
					prompt = prompt,
					pip_corner = corner_str,
				})
				send_mux(cid, { _ack = true, pane = target_pane, queued = true, position = #q }, true)
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

		send_mux(cid, { _ack = true, pane = final_pane }, true)
		register_waiter(final_pane, cid, pending_bootstrap_prompt)
		return
	end

	send_mux(cid, { ok = false, error = "unknown op: " .. tostring(op) }, false)
end

local ensure_mux: () -> ()

local function on_mux_stdout(line: string, cx: WindowCx?)
	if line == "" then
		return
	end
	local ok_j, msg = pcall(tern.json.decode, line)
	if not ok_j or type(msg) ~= "table" then
		return
	end
	if msg.type == "ready" then
		return
	end
	local cid = tonumber(msg.id)
	if not cid then
		return
	end
	if msg.disconnected == true then
		drop_disconnected_cid(cid)
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
	local mux_script = tern.plugin.dir .. "/mux.py"
	local ok_sp, child_or_err = pcall(function()
		return tern.process.spawn({ "python3", "-u", mux_script, ipc_dir }, {
			split = "lines",
			stdout = on_mux_stdout,
			exit = function(_res: SpawnExit, _cx: WindowCx?)
				mux_child = nil
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
		tern.log.error("wingman: failed to spawn mux.py:", tostring(child_or_err))
		if not unloading then
			tern.timer(2000, function(_later: WindowCx?)
				ensure_mux()
			end)
		end
	end
end

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
local function start(_cx: WindowCx?)
	if started then
		return
	end
	started = true
	load_bindings()
	ensure_mux()
end

tern.on("window_start", start)
tern.timer(0, start)
