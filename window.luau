-- Wingman: Native WindowCx.agents TSP bridge for coding agents running in Tern.
local runtime_dir = tern.getenv("XDG_RUNTIME_DIR")
local home_dir = tern.getenv("HOME")
local daemon_socket = tern.getenv("TERN_DAEMON_SOCKET")
local ipc_dir = (runtime_dir and runtime_dir ~= "" and (runtime_dir .. "/tern-wingman"))
	or ((home_dir or "/tmp") .. "/.cache/tern-wingman")

-- pane_id -> { req = table, started_ms = number, saw_working = boolean, idle_since = number?, pending_prompt = string?, ask_deadline = number? }
local pending_waits: { [number]: any } = {}
local claimed_ids: { [string]: number } = {}

local function same_daemon(req_socket: any): boolean
	if req_socket == nil or req_socket == tern.json.null or req_socket == "" then
		return true
	end
	if daemon_socket and daemon_socket ~= "" then
		return req_socket == daemon_socket
	end
	return type(req_socket) == "string" and string.sub(req_socket, -12) == "/daemon.sock"
end

local function post_reply(req: any, payload: any)
	local port = tonumber(req.port)
	if not port or port < 1 or port > 65535 then
		return
	end
	local url = "http://127.0.0.1:" .. tostring(port) .. "/reply"
	tern.fetch(url, {
		method = "POST",
		headers = {
			["Authorization"] = "Bearer " .. tostring(req.token or ""),
			["Content-Type"] = "application/json",
		},
		body = tern.json.encode(payload),
		timeout_ms = 5000,
	}, function(_res) end)
end

local function find_agent_info(cx: WindowCx, pane_id: number): any
	for _, a in ipairs(cx.agents:list()) do
		if a.pane == pane_id then
			return a
		end
	end
	return nil
end

local function collect_turn_output(cx: WindowCx, pane_id: number): (string?, any)
	local info = find_agent_info(cx, pane_id)
	local last_msg = info and info.last_message or nil
	if last_msg == tern.json.null then
		last_msg = nil
	end
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

local function finish_wait(cx: WindowCx, pane_id: number, status: string, err_msg: string?)
	local w = pending_waits[pane_id]
	if not w then
		return
	end
	pending_waits[pane_id] = nil
	local last_msg, transcript = collect_turn_output(cx, pane_id)
	post_reply(w.req, {
		ok = (status == "done" or status == "idle"),
		pane = pane_id,
		status = status,
		error = err_msg,
		last_message = last_msg or "",
		transcript = transcript,
	})
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	local w = pending_waits[ev.pane]
	if not w then
		return
	end
	if ev.new == "working" then
		w.saw_working = true
		w.idle_since = nil
	elseif ev.new == "waiting_input" and w.pending_prompt == nil then
		finish_wait(cx, ev.pane, "waiting_input", "Agent is waiting for interactive user input")
	elseif ev.new == "exited" then
		finish_wait(cx, ev.pane, "exited", "Agent process exited")
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	local w = pending_waits[ev.pane]
	if not w or w.pending_prompt ~= nil then
		return
	end
	finish_wait(cx, ev.pane, ev.result, nil)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if pending_waits[ev.pane] then
		finish_wait(cx, ev.pane, "closed", "Agent pane was closed")
	end
end)

local function handle_request(cx: WindowCx, req: any)
	local op = req.op
	local anchor = tonumber(req.anchor_pane)

	if op == "status" then
		local my_tab = anchor and cx.session:tab_of(anchor) or nil
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
			table.insert(out, {
				pane = a.pane,
				tab = atab,
				same_tab = (my_tab ~= nil and atab == my_tab),
				cwd = a.cwd,
				state = a.state,
				model = (a.model ~= tern.json.null) and a.model or nil,
				command = (a.command ~= tern.json.null) and a.command or nil,
				last_message = (a.last_message ~= tern.json.null) and a.last_message or nil,
				delivery_error = (a.delivery_error ~= tern.json.null) and a.delivery_error or nil,
			})
		end
		post_reply(req, {
			ok = true,
			window_key = cx:window_key(),
			anchor_tab = my_tab,
			agents = tern.json.array(out),
			floats = floats,
		})
		return
	end

	if op == "pip" then
		local ok_f, err_f = cx.layout:float(tonumber(req.target_pane) :: number, anchor, req.corner or "br", { focus = false })
		post_reply(req, { ok = ok_f, error = err_f })
		return
	end

	if op == "dock" then
		local ok_d, err_d = cx.layout:dock(tonumber(req.target_pane) :: number, anchor, req.dir or "right", { focus = false })
		post_reply(req, { ok = ok_d, error = err_d })
		return
	end

	if op == "interrupt" then
		local ok_i, err_i = pcall(function()
			cx.agents:interrupt(tonumber(req.target_pane) :: number)
		end)
		post_reply(req, { ok = ok_i, error = not ok_i and tostring(err_i) or nil })
		return
	end

	if op == "stop" then
		local ok_s, err_s = pcall(function()
			cx.agents:stop(tonumber(req.target_pane) :: number)
		end)
		post_reply(req, { ok = ok_s, error = not ok_s and tostring(err_s) or nil })
		return
	end

	if op == "transcript" then
		local tp = tonumber(req.target_pane) :: number
		local ok_t, msgs = pcall(function()
			return cx.agents:transcript(tp, { last = tonumber(req.last) or 10 })
		end)
		if not ok_t then
			post_reply(req, { ok = false, error = tostring(msgs) })
		else
			post_reply(req, { ok = true, messages = tern.json.array(msgs) })
		end
		return
	end

	if op == "dispatch" then
		if not anchor then
			post_reply(req, { ok = false, error = "missing anchor_pane" })
			return
		end
		local prompt = tostring(req.prompt or "")
		local cwd = tostring(req.cwd or "")
		local cmd = req.command
		local target_pane = req.target_pane and tonumber(req.target_pane) or nil
		local reset_new = req.reset_new == true
		local pip_corner = req.pip_corner

		if target_pane and reset_new then
			pcall(function()
				cx.agents:stop(target_pane :: number)
			end)
			target_pane = nil
		end

		local pending_bootstrap_prompt: string? = nil

		if target_pane then
			local ainfo = find_agent_info(cx, target_pane)
			if ainfo and ainfo.state == "working" then
				post_reply(req, { ok = false, error = "target agent pane is currently busy (working)" })
				return
			end
			local ok_ask, err_ask = pcall(function()
				cx.agents:ask(target_pane :: number, prompt)
			end)
			if not ok_ask then
				post_reply(req, { ok = false, error = "cx.agents:ask failed: " .. tostring(err_ask) })
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
					post_reply(req, { ok = false, error = "cx.agents:start failed: " .. tostring(res_st) })
					return
				end
				target_pane = res_st
				cx.layout:focus(anchor)
			else
				-- User is focused on another pane/tab: split anchor silently without stealing focus, then TSP-ask once ready
				local new_p = cx.layout:split(anchor, "right", { cwd = cwd, command = cmd }, { focus = false })
				if not new_p then
					post_reply(req, { ok = false, error = "cx.layout:split returned nil" })
					return
				end
				target_pane = new_p
				pending_bootstrap_prompt = prompt
			end
		end

		if pip_corner and target_pane then
			pcall(function()
				cx.layout:float(target_pane :: number, anchor, pip_corner, { focus = false })
			end)
		end

		pending_waits[target_pane :: number] = {
			req = req,
			started_ms = tern.now(),
			saw_working = false,
			idle_since = nil,
			pending_prompt = pending_bootstrap_prompt,
			ask_deadline = pending_bootstrap_prompt and (tern.now() + 20000) or nil,
		}
		return
	end

	post_reply(req, { ok = false, error = "unknown op: " .. tostring(op) })
end

local function tick(cx: WindowCx?)
	if cx then
		local now = tern.now()

		-- 1. Advance pending bootstrap prompts & monitor delivery_error / fallback idle transitions
		for pane_id, w in pairs(pending_waits) do
			if w.pending_prompt ~= nil then
				if find_agent_info(cx, pane_id) ~= nil then
					local ok_ask = pcall(function()
						cx.agents:ask(pane_id, w.pending_prompt)
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
					if ainfo.delivery_error and ainfo.delivery_error ~= tern.json.null and ainfo.delivery_error ~= "" then
						finish_wait(cx, pane_id, "failed", "TSP delivery error: " .. tostring(ainfo.delivery_error))
					elseif ainfo.state == "working" then
						w.saw_working = true
						w.idle_since = nil
					elseif ainfo.state == "waiting_input" then
						finish_wait(cx, pane_id, "waiting_input", "Agent is waiting for interactive user input")
					elseif ainfo.state == "exited" then
						finish_wait(cx, pane_id, "exited", "Agent process exited")
					elseif ainfo.state == "idle" and w.saw_working then
						w.idle_since = w.idle_since or now
						if now - w.idle_since >= 1000 then
							finish_wait(cx, pane_id, "done", nil)
						end
					end
				end
			end
		end

		-- 2. Prune old claimed IDs (> 60s)
		for cid, ts in pairs(claimed_ids) do
			if now - ts > 60000 then
				claimed_ids[cid] = nil
			end
		end

		-- 3. Poll IPC directory for atomic .json requests belonging to panes in this window
		local ok_ex, exists = pcall(tern.fs.exists, ipc_dir)
		if ok_ex and exists then
			local ok_ls, files = pcall(tern.fs.list, ipc_dir)
			if ok_ls and type(files) == "table" then
				for _, fname in ipairs(files) do
					if string.sub(fname, 1, 1) ~= "." and string.sub(fname, -5) == ".json" and not claimed_ids[fname] then
						local fpath = ipc_dir .. "/" .. fname
						local ok_r, raw = pcall(tern.fs.read, fpath, 262144)
						if ok_r and type(raw) == "string" and raw ~= "" then
							local ok_j, req = pcall(tern.json.decode, raw)
							if ok_j and type(req) == "table" and same_daemon(req.daemon_socket) then
								local anchor = tonumber(req.anchor_pane)
								local owns = (anchor == nil) or (cx.session:pane(anchor) ~= nil)
								if owns then
									claimed_ids[fname] = now
									pcall(tern.fs.remove, fpath)
									local ok_h, err_h = pcall(handle_request, cx, req)
									if not ok_h then
										post_reply(req, { ok = false, error = tostring(err_h) })
									end
								end
							end
						end
					end
				end
			end
		end
	end

	tern.timer(300, tick)
end

local started = false
local function start(cx: WindowCx?)
	if started then
		return
	end
	started = true
	tick(cx)
end

tern.on("window_start", start)
tern.timer(0, start)
