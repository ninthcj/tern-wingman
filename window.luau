--!strict
-- Wingman: Bidirectional event-driven WindowCx.agents TSP bridge & ownership graph for coding agents in Tern.

local tsp = require("./tsp")
local ownership = require("./state")
local Queue = require("./queue")

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

-- Live panel (radar.luau): optional UI over this control plane. A load error must never take the plugin down.
local radar_loaded, radar = pcall(function()
	return require("./radar")
end)
if not radar_loaded then
	tern.log.error("wingman: radar.luau failed to load:", tostring(radar))
end

-- Tells the panel that ownership, placement, queues or escalations may have moved.
local function notify_radar()
	if radar_loaded then
		pcall(radar.on_state_change)
	end
end

local state = ownership.new({ kv = tern.kv, log = tern.log, notify = notify_radar })

type WaitEntry = {
	cids: { number },
	started_ms: number,
	saw_working: boolean,
	idle_since: number?,
}

local pending_waits: { [number]: WaitEntry } = {}
local dispatches = Queue.new(tern.now)
local dispatch_ids_loaded = false
local dispatch_inflight: { [number]: number } = {}
-- Native per-owner FIFO callback queue when owner_pane is busy (`working` / `waiting_input`)
local queued_callbacks: { [number]: { string } } = {}
-- Tracks whether a wingman pane is executing an unsolicited turn (no active `pending_waits` waiter)
local unsolicited_working: { [number]: boolean } = {}
-- Tracks whether a wingman pane already called `report` (`kind ~= "progress"`) during the current turn
local reported_in_turn: { [number]: boolean } = {}
-- Panes intentionally interrupted via `wingman.py interrupt` (suppresses fault escalation until next turn)
local manual_interrupt: { [number]: boolean } = {}

local mux_child: Child? = nil
local unloading = false
local watchdog_armed = false

local WATCHDOG_MS = 500
local DISPATCH_GRACE_MS = 2 * WATCHDOG_MS

local function load_dispatch_ids(cx: WindowCx)
	if dispatch_ids_loaded then
		return
	end
	-- Prompts are transient, but a reloaded window must never reuse a previously issued ID.
	local key = "queue_id_v1:" .. cx:window_key()
	local last = tern.kv.get(key)
	if last ~= nil and (type(last) ~= "number" or last < 0 or last % 1 ~= 0) then
		error("invalid saved Wingman queue ID")
	end
	dispatches = Queue.new(tern.now, last, function(id: number): (boolean, string?)
		local ok, err = pcall(function(): any
			tern.kv.set(key, id)
			return nil
		end)
		return ok, if ok then nil else "could not reserve queue ID: " .. tostring(err)
	end)
	dispatch_ids_loaded = true
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
		last_msg = tsp.strip_turn_footer(last_msg)
	end
	return last_msg, transcript
end

local ensure_watchdog: () -> ()

local function has_pending_dispatch(pane: number): boolean
	local deadline = dispatch_inflight[pane]
	return pending_waits[pane] ~= nil or (deadline ~= nil and tern.now() < deadline)
end

local function ask_worker(cx: WindowCx, pane: number, prompt: string): (boolean, any)
	dispatch_inflight[pane] = tern.now() + DISPATCH_GRACE_MS
	local ok, err = pcall(function(): any
		cx.agents:ask(pane, prompt)
		return nil
	end)
	if not ok then
		dispatch_inflight[pane] = nil
	end
	ensure_watchdog()
	return ok, err
end

local function has_active_timers(): boolean
	return next(pending_waits) ~= nil or dispatches.has_any() or next(queued_callbacks) ~= nil or next(dispatch_inflight) ~= nil
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
	if not ainfo or ainfo.state ~= "idle" or has_pending_dispatch(owner_pane) then
		return false
	end
	local combined = table.concat(q, "\n\n---\n\n")
	local ok_ask = ask_worker(cx, owner_pane, combined)
	if ok_ask then
		queued_callbacks[owner_pane] = nil
		return true
	end
	return false
end

local CALLBACK_BODY_MAX_BYTES = 3600

local function deliver_to_owner(
	cx: WindowCx,
	owner_pane: number,
	worker_pane: number,
	tag: string,
	body: string
): (boolean, boolean, number)
	local delivered_body = body
	if #delivered_body > CALLBACK_BODY_MAX_BYTES then
		delivered_body = tsp.clip_utf8_bytes(delivered_body, CALLBACK_BODY_MAX_BYTES)
			.. string.format(
				"\n\n… (truncated from %d bytes; run `wingman transcript --pane %d --last 2` for full output)",
				#body,
				worker_pane
			)
	end
	local formatted = string.format("[Wingman %s · pane %d]\n%s", tag, worker_pane, delivered_body)
	local existing_q = queued_callbacks[owner_pane]
	local ainfo = find_agent_info(cx, owner_pane)
	if ainfo ~= nil and ainfo.state == "idle" and not has_pending_dispatch(owner_pane)
		and dispatches.count(owner_pane) == 0 and (existing_q == nil or #existing_q == 0) then
		local ok_ask = ask_worker(cx, owner_pane, formatted)
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

local function notify_waiting_input(cx: WindowCx, worker_pane: number)
	tern.timer(120, function(later_cx: WindowCx?)
		local lcx = later_cx or cx
		local ainfo = find_agent_info(lcx, worker_pane)
		if not ainfo or ainfo.state ~= "waiting_input" or pending_waits[worker_pane] ~= nil then
			return
		end
		local owner = state.owner_of_pane(lcx, worker_pane)
		if owner == nil or not state.is_auto_callback_enabled(owner) then
			return
		end
		local key, body = tsp.build_waiting_summary(lcx, worker_pane)
		if not state.record_waiting(worker_pane, key) then
			return
		end
		deliver_to_owner(lcx, owner, worker_pane, "waiting_input", body)
	end)
end

local function deliver_fault_if_needed(cx: WindowCx, worker_pane: number, fallback_reason: string?): boolean
	local owner = state.owner_of_pane(cx, worker_pane)
	if owner == nil or not state.is_auto_callback_enabled(owner) then
		return false
	end
	local has_fault, key, summary = tsp.inspect_fault_surface(cx, worker_pane)
	if not has_fault then
		if fallback_reason == nil then
			return false
		end
		key, summary = "fault:" .. fallback_reason, fallback_reason
	end
	if not state.record_waiting(worker_pane, key :: string) then
		return false
	end
	local body = tostring(summary)
		.. "\n\nRecover: run `wingman retry --pane " .. worker_pane .. "` (sends native `/retry`, equivalent to F5) for transient stream/network/edit-preview glitches (up to 2-3 retries), or consult the user if it is a persistent quota/auth/config error."
	deliver_to_owner(cx, owner, worker_pane, "fault · retryable", body)
	return true
end

local function reply_to_queued(items: { Queue.Item }, status: string, reason: string, last_message: string?, transcript: any?)
	for _, item in items do
		if item.cid ~= nil then
			send_mux(item.cid, {
				ok = false,
				pane = item.pane,
				queue_id = item.id,
				status = status,
				error = reason,
				last_message = last_message or "",
				transcript = transcript or tern.json.array(),
			}, false)
		end
	end
end

local function promote_next_queued(cx: WindowCx, pane_id: number): number?
	while true do
		local item = dispatches.pop_next(pane_id)
		if not item then
			return nil
		end
		local ok, err = ask_worker(cx, pane_id, item.prompt)
		if ok then
			reported_in_turn[pane_id] = false
			unsolicited_working[pane_id] = item.cid == nil
			if item.cid ~= nil then
				pending_waits[pane_id] = {
					cids = { item.cid },
					started_ms = tern.now(),
					saw_working = false,
					idle_since = nil,
				}
				ensure_watchdog()
			end
			return item.id
		end
		local reason = "queued cx.agents:ask failed: " .. tostring(err)
		if item.cid ~= nil then
			reply_to_queued({ item }, "failed", reason)
		else
			local owner = state.owner_of_pane(cx, pane_id)
			if owner ~= nil and state.is_auto_callback_enabled(owner) then
				deliver_to_owner(cx, owner, pane_id, "auto-callback · failed", reason)
			end
		end
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
		local owner = state.owner_of_pane(cx, pane_id)
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
		reply_to_queued(dispatches.clear_pane(pane_id), status, err_msg or ("queued dispatch aborted: " .. status), last_msg, transcript)
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
	dispatches.drop_cid(cid)
end

local function watchdog_step(cx: WindowCx?)
	watchdog_armed = false
	if not has_active_timers() then
		return
	end
	if cx then
		local now = tern.now()
		for pane, deadline in dispatch_inflight do
			if now >= deadline then
				dispatch_inflight[pane] = nil
			end
		end
		for pane_id, w in pairs(pending_waits) do
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

		-- Promote queued dispatches for panes whose active turn wasn't started via `pending_waits`
		for _, pane_id in dispatches.panes() do
			if not has_pending_dispatch(pane_id) then
				local ainfo = find_agent_info(cx, pane_id)
				if not ainfo and cx.session:pane(pane_id) == nil then
					reply_to_queued(dispatches.clear_pane(pane_id), "closed", "Agent pane disappeared")
				elseif ainfo and ainfo.state == "exited" then
					reply_to_queued(dispatches.clear_pane(pane_id), "exited", "Agent process exited")
				elseif ainfo and ainfo.state == "idle" then
					promote_next_queued(cx, pane_id)
				end
			end
		end

		-- Flush queued owner callbacks once the owner pane becomes idle
		for owner_pane, _ in pairs(queued_callbacks) do
			if pending_waits[owner_pane] == nil and dispatches.count(owner_pane) == 0 then
				flush_queued_callbacks(cx, owner_pane)
			end
		end
	end
	if has_active_timers() and not watchdog_armed then
		watchdog_armed = true
		tern.timer(WATCHDOG_MS, watchdog_step)
	end
	notify_radar()
end

ensure_watchdog = function()
	if not watchdog_armed and has_active_timers() then
		watchdog_armed = true
		tern.timer(WATCHDOG_MS, watchdog_step)
	end
end

local function seed_inflight_unsolicited_turns(cx: WindowCx)
	state.prune_notifications(cx)
	for _, a in ipairs(cx.agents:list()) do
		if a.state == "working" and pending_waits[a.pane] == nil and dispatches.count(a.pane) == 0 then
			if state.owner_of_pane(cx, a.pane) ~= nil then
				unsolicited_working[a.pane] = true
			end
		elseif a.state == "waiting_input" and pending_waits[a.pane] == nil and state.owner_of_pane(cx, a.pane) ~= nil then
			notify_waiting_input(cx, a.pane)
		elseif a.state == "idle" and pending_waits[a.pane] == nil and state.owner_of_pane(cx, a.pane) ~= nil then
			if tsp.inspect_fault_surface(cx, a.pane) then
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
		if tsp.inspect_fault_surface(lcx, pane) then
			unsolicited_working[pane] = false
			reported_in_turn[pane] = false
			deliver_fault_if_needed(lcx, pane, nil)
		end
	end)
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	if ev.new ~= "idle" then
		dispatch_inflight[ev.pane] = nil
	end
	if ev.new == "working" then
		manual_interrupt[ev.pane] = nil
		state.clear_waiting(ev.pane)
	elseif ev.new ~= "waiting_input" and not string.find(state.waiting_key(ev.pane) or "", "^fault:") then
		state.clear_waiting(ev.pane)
	end
	local w = pending_waits[ev.pane]
	if w then
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
		if state.owner_of_pane(cx, ev.pane) ~= nil then
			notify_waiting_input(cx, ev.pane)
		end
	elseif ev.old == "waiting_input" and ev.new == "working" and state.owner_of_pane(cx, ev.pane) ~= nil then
		unsolicited_working[ev.pane] = true
	elseif ev.new == "working" and ev.old ~= "working" and dispatches.count(ev.pane) == 0 then
		if state.owner_of_pane(cx, ev.pane) ~= nil then
			unsolicited_working[ev.pane] = true
			reported_in_turn[ev.pane] = false
		end
	elseif ev.old == "working" and ev.new == "idle" and state.owner_of_pane(cx, ev.pane) ~= nil then
		settle_stalled_fault(cx, ev.pane)
	end
	if ev.new == "idle" and queued_callbacks[ev.pane] ~= nil and dispatches.count(ev.pane) == 0 then
		flush_queued_callbacks(cx, ev.pane)
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	dispatch_inflight[ev.pane] = nil
	if ev.result == "done" then
		state.clear_waiting(ev.pane)
	end
	-- 1. If this pane is an owner with pending wingman callbacks, flush them as soon as its turn finishes cleanly
	if queued_callbacks[ev.pane] ~= nil and ev.result == "done" and dispatches.count(ev.pane) == 0 then
		flush_queued_callbacks(cx, ev.pane)
	end

	-- 2. Active synchronous `send` or `await` waiter gets its reply over the mux socket.
	local w = pending_waits[ev.pane]
	if w then
		finish_wait(cx, ev.pane, ev.result, nil)
		return
	end

	-- 3. If the completed turn was an async/unsolicited turn, push its completion to `owner` FIRST (before promoting next queued item!)
	local was_unsolicited = unsolicited_working[ev.pane] == true
	if (ev.result == "failed" or ev.result == "exited") and not manual_interrupt[ev.pane] and state.owner_of_pane(cx, ev.pane) ~= nil then
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
		local owner = state.owner_of_pane(cx, ev.pane)
		local has_next_q = dispatches.count(ev.pane) > 0 and ev.result == "done"
		if
			owner ~= nil
			and not already_reported
			and state.is_auto_callback_enabled(owner)
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

	-- 4. Queued `send` dispatches promote from the head
	if dispatches.count(ev.pane) > 0 then
		if ev.result == "done" then
			promote_next_queued(cx, ev.pane)
		else
			reply_to_queued(dispatches.clear_pane(ev.pane), ev.result, "Previous turn ended with " .. ev.result)
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
			if pending_waits[finished_pane] == nil and dispatches.count(finished_pane) == 0 then
				local ainfo = find_agent_info(later_cx, finished_pane)
				if ainfo and ainfo.state == "working" and state.owner_of_pane(later_cx, finished_pane) ~= nil then
					unsolicited_working[finished_pane] = true
				end
			end
		end)
	end
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	dispatch_inflight[ev.pane] = nil
	state.unbind_pane(ev.pane)
	state.clear_waiting(ev.pane)
	unsolicited_working[ev.pane] = nil
	reported_in_turn[ev.pane] = nil
	queued_callbacks[ev.pane] = nil
	manual_interrupt[ev.pane] = nil
	if pending_waits[ev.pane] then
		finish_wait(cx, ev.pane, "closed", "Agent pane was closed")
	else
		reply_to_queued(dispatches.clear_pane(ev.pane), "closed", "Agent pane was closed")
	end
end)

local function register_waiter(pane_id: number, cid: number)
	unsolicited_working[pane_id] = false
	reported_in_turn[pane_id] = false
	local existing = pending_waits[pane_id]
	if existing then
		table.insert(existing.cids, cid)
	else
		pending_waits[pane_id] = { cids = { cid }, started_ms = tern.now(), saw_working = false }
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
	local bound_owner = state.owner_of_pane(cx, worker_pane)
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

-- Cores shared by the RPC ops and the live panel's buttons, so both keep the same control-plane bookkeeping.
local function interrupt_pane(cx: WindowCx, tp: number): (boolean, string?)
	manual_interrupt[tp] = true
	unsolicited_working[tp] = false
	local ok_i, err_i = pcall(function()
		cx.agents:interrupt(tp)
	end)
	return ok_i, if not ok_i then tostring(err_i) else nil
end

local function cancel_queued(pane: number, position: number?, id: number?): (number, string?)
	if id ~= nil then
		local item, err = dispatches.cancel_by_id(id, pane)
		if not item then
			return 0, err
		end
		reply_to_queued({ item }, "cancelled", "Cancelled from queue via unqueue")
		return 1, nil
	end
	local items, err = dispatches.cancel_at(pane, position)
	reply_to_queued(items, "cancelled", "Cancelled from queue via unqueue")
	return #items, err
end

-- Sends `/retry` (F5) to an idle/failed pane; the third value is the busy state that refused it.
local function retry_pane(cx: WindowCx, tp: number): (boolean, string?, string?)
	local ainfo = find_agent_info(cx, tp)
	if ainfo and (ainfo.state == "working" or ainfo.state == "waiting_input") then
		return false, "target pane is " .. ainfo.state .. " (not idle/failed)", ainfo.state
	end
	if has_pending_dispatch(tp) then
		return false, "target pane has a dispatch in flight", "working"
	end
	local ok_r, err_r = ask_worker(cx, tp, "/retry")
	if not ok_r then
		return false, "cx.agents:ask /retry failed: " .. tostring(err_r), nil
	end
	state.clear_waiting(tp)
	manual_interrupt[tp] = nil
	return true, nil, nil
end

type WorkerLayout = "split" | "down" | "pip" | "tab" | "park"

local function corner_of(value: any): Corner?
	return if value == "tl" or value == "tr" or value == "bl" or value == "br" then value else nil
end

local function down_target(cx: WindowCx, anchor: number, moving: number?): number
	local tab = cx.session:tab_of(anchor)
	local layout = if tab then cx.session:layout(tab) else nil
	if not layout then
		return anchor
	end
	local function last_worker(node: TabTree?): number?
		if not node then
			return nil
		end
		local pane = node.pane
		if pane then
			return if pane ~= moving and state.raw_owner(pane) == anchor then pane else nil
		end
		return last_worker(node[2]) or last_worker(node[1])
	end
	-- Prefer the bottom worker of the nearest right column along the anchor's path.
	local function find(node: TabTree?): (boolean, number?)
		if not node then
			return false, nil
		end
		if node.pane then
			return node.pane == anchor, nil
		end
		local found, worker = find(node[1])
		if found then
			return true, worker or (if node.split == "right" then last_worker(node[2]) else nil)
		end
		return find(node[2])
	end
	local _, worker = find(layout.root)
	return worker or anchor
end

-- Dynamic PiP placement & size: scale to the owner's actual share of the tab and avoid overlapping sibling floats.
local PIP_CORNER_ORDER: { Corner } = { "br", "tr", "bl", "tl" }

local function pane_shares(cx: WindowCx, pane: number): (number, number)
	local tab = cx.session:tab_of(pane)
	local layout = if tab then cx.session:layout(tab) else nil
	if not layout then
		return 1, 1
	end
	local function walk(node: TabTree?, sx: number, sy: number): (number?, number?)
		if not node then
			return nil, nil
		end
		if node.pane then
			if node.pane == pane then
				return sx, sy
			end
			return nil, nil
		end
		local r = node.ratio or 0.5
		local horiz = node.split == "right"
		local x1, y1 = walk(node[1], if horiz then sx * r else sx, if horiz then sy else sy * r)
		if x1 ~= nil then
			return x1, y1
		end
		return walk(node[2], if horiz then sx * (1 - r) else sx, if horiz then sy else sy * (1 - r))
	end
	local sx, sy = walk(layout.root, 1, 1)
	return sx or 1, sy or 1
end

local function first_leaf(node: TabTree?, skip: number, avoid: number?): number?
	if node == nil then
		return nil
	elseif node.pane ~= nil then
		return if node.pane ~= skip and node.pane ~= avoid then node.pane else nil
	end
	return first_leaf(node[1], skip, avoid) or first_leaf(node[2], skip, avoid)
end

local function tab_layout(cx: WindowCx, pane: number): TabLayout?
	local tab = cx.session:tab_of(pane)
	return if tab ~= nil then cx.session:layout(tab) else nil
end

local function live_panel_pane(cx: WindowCx): number?
	for _, info in cx.canvas:list() do
		if info.title == "Wingman Live" and info.owner == tern.plugin.id then
			return info.pane
		end
	end
	return nil
end

local function can_pip(cx: WindowCx, pane: number): boolean
	local layout = tab_layout(cx, pane)
	return layout ~= nil and first_leaf(layout.root, pane, nil) ~= nil
end

local function float_worker(cx: WindowCx, pane: number, over: number?, requested: Corner?): (boolean, string?)
	if over == nil then
		local layout = tab_layout(cx, pane)
		if layout == nil then
			return false, "agent is not in a tiled tab"
		end
		over = first_leaf(layout.root, pane, live_panel_pane(cx)) or first_leaf(layout.root, pane, nil)
		if over == nil then
			return false, "no sibling pane to float over"
		end
	end
	local sx, sy = pane_shares(cx, over :: number)
	local used: { [string]: boolean } = {}
	local peers = 0
	if over ~= nil then
		local tab = cx.session:tab_of(over)
		local layout = if tab then cx.session:layout(tab) else nil
		if layout and layout.floats then
			for _, fl in layout.floats do
				if fl.over == over and fl.pane ~= pane then
					peers += 1
					used[fl.corner] = true
				end
			end
		end
	end
	local chosen: Corner = requested or "br"
	if requested == nil then
		for _, c in PIP_CORNER_ORDER do
			if not used[c] then
				chosen = c :: Corner
				break
			end
		end
	end
	-- Target ~36% of the full tab width so PiP stays readable over narrow splits; shrink height when sibling floats share `over`.
	local w = math.clamp(0.36 / math.max(sx, 0.25), 0.34, 0.68)
	local base_h = if peers >= 1 then 0.38 else 0.46
	local h = math.clamp(base_h / math.max(sy, 0.4), 0.34, 0.56)
	return cx.layout:float(pane, over, chosen, { focus = false, size = { w, h } })
end

-- Choose a tiled slot beside `anchor` without crushing `anchor`: stack `"down"` under an existing
-- right-column worker when one already exists, otherwise split `"right"` beside `anchor`.
local function tiled_slot(cx: WindowCx, anchor: number, moving: number?): (number, "right" | "down")
	local existing = down_target(cx, anchor, moving)
	if existing ~= anchor then
		return existing, "down"
	end
	return anchor, "right"
end

local function dock_worker(cx: WindowCx, pane: number, over: number?, dir: Dir?): (boolean, string?)
	if over ~= nil and (dir == nil or dir == "right") then
		local slot_target, slot_dir = tiled_slot(cx, over, pane)
		return cx.layout:dock(pane, slot_target, slot_dir :: Dir, { focus = false })
	end
	return cx.layout:dock(pane, over, dir or "right", { focus = false })
end

local function park_pane(cx: WindowCx, pane: number): (boolean, string?)
	return cx.layout:park(pane)
end

local function unpark_pane(cx: WindowCx, pane: number): (boolean, string?)
	local focused = cx.session:focused()
	local current = if focused ~= nil then tab_layout(cx, focused) else nil
	local panel = if current then live_panel_pane(cx) else nil
	local sibling = if current and panel and focused == panel then first_leaf(current.root, pane, panel) else nil
	local ok, err = cx.layout:unpark(pane, { focus = false })
	if not ok then
		return false, err
	end
	local owner = state.owner_of_pane(cx, pane)
	local target = if owner ~= nil and current ~= nil and cx.session:tab_of(owner) == current.tab then owner else sibling
	if target ~= nil then
		local slot_target, slot_dir = tiled_slot(cx, target, pane)
		if slot_target ~= pane then
			cx.layout:move(pane, slot_target, slot_dir :: Dir, { focus = false })
		end
	end
	return true, nil
end

local function place_worker(cx: WindowCx, pane: number, anchor: number, form: WorkerLayout, corner: Corner): (boolean, string?)
	if form == "pip" then
		return float_worker(cx, pane, anchor, corner)
	elseif form == "park" then
		return park_pane(cx, pane)
	elseif form == "tab" then
		local tab, err = cx.layout:move_to_new_tab(pane, nil, { focus = false })
		return tab ~= nil, err
	end
	local target: number, dir: Dir
	if form == "down" then
		target, dir = down_target(cx, anchor, pane), "down"
	else
		target, dir = tiled_slot(cx, anchor, pane)
	end
	local info = cx.session:pane(pane)
	if info and info.floating then
		return cx.layout:dock(pane, target, dir, { focus = false })
	end
	local ok = cx.layout:move(pane, target, dir, { focus = false })
	return ok, if ok then nil else "could not move wingman beside target pane"
end

local function spawn_worker(cx: WindowCx, anchor: number, form: WorkerLayout, cwd: string, command: string, corner: Corner): (number?, string?)
	local launch = { cwd = cwd, command = command }
	local pane: number?
	if form == "tab" then
		pane = cx.layout:new_tab(launch, { focus = false })
	else
		local target: number, dir: Dir
		if form == "down" then
			target, dir = down_target(cx, anchor, nil), "down"
		elseif form == "split" then
			target, dir = tiled_slot(cx, anchor, nil)
		else
			target, dir = anchor, "right"
		end
		pane = cx.layout:split(target, dir, launch, { focus = false })
	end
	if not pane then
		return nil, "could not open wingman with layout " .. form
	end
	if form == "pip" or form == "park" then
		local ok, err = place_worker(cx, pane, anchor, form, corner)
		if not ok then
			cx.layout:close(pane)
			return nil, err or ("could not place wingman in " .. form)
		end
	end
	return pane, nil
end

local function select_worker(cx: WindowCx, anchor: number?, value: any, cwd: any): (number?, string?)
	if value ~= nil and value ~= tern.json.null then
		local pane = tonumber(value)
		if not pane or pane == anchor or cx.session:pane(pane) == nil then
			return nil, "invalid target_pane (must be an existing pane other than the caller)"
		end
		return pane, nil
	end
	local workers: { number } = if anchor then state.workers_of_owner(cx, anchor) else {}
	if #workers == 1 then
		return workers[1], nil
	elseif #workers == 0 then
		return nil, "no wingman pane is bound to this pane; pass --pane <id>"
	end
	if type(cwd) == "string" and cwd ~= "" then
		local match: number? = nil
		for _, pane in workers do
			local info = cx.session:pane(pane)
			if info and info.cwd == cwd then
				if match then
					match = nil
					break
				end
				match = pane
			end
		end
		if match then
			return match, nil
		end
	end
	local ids: { string } = table.create(#workers)
	for i, worker in workers do
		ids[i] = tostring(worker)
	end
	return nil, "multiple bound wingman panes (" .. table.concat(ids, ", ") .. "); pass --pane <id> or a unique --cwd"
end

local function stop_worker(cx: WindowCx, pane: number): (boolean, string?)
	local ok, err = pcall(function()
		cx.agents:stop(pane)
	end)
	if ok then
		state.unbind_pane(pane)
	end
	return ok, if ok then nil else tostring(err)
end

local function supplied(value: any): boolean
	return value ~= nil and value ~= tern.json.null
end

local function positive_integer(value: any): number?
	local n = tonumber(value)
	return if n ~= nil and n > 0 and n <= 9007199254740991 and n % 1 == 0 then n else nil
end

local function queue_access(cx: WindowCx, anchor: number, pane: number): string?
	if cx.session:pane(pane) == nil then
		return "queue pane is not live: " .. pane
	end
	local cycle = state.ownership_cycle(anchor, pane)
	if cycle then
		return cycle
	end
	local owner = state.owner_of_pane(cx, pane)
	return if owner ~= nil and owner ~= anchor then "queue pane is bound to pane " .. owner else nil
end

local function queue_source(cx: WindowCx, anchor: number, req: any, id: number?): (number?, string?)
	if id ~= nil then
		local pane = dispatches.find(id)
		if pane == nil then
			return nil, "queue item " .. id .. " is no longer queued"
		end
		if supplied(req.target_pane) and tonumber(req.target_pane) ~= pane then
			return nil, "queue item is not on the expected pane"
		end
		return pane, nil
	end
	if not supplied(req.target_pane) and #state.workers_of_owner(cx, anchor) == 0 then
		local tab = cx.session:tab_of(anchor)
		local found: number? = nil
		if tab ~= nil then
			for _, agent in cx.agents:list() do
				local pane = agent.pane
				if pane ~= anchor and agent.state ~= "exited" and cx.session:tab_of(pane) == tab
					and state.owner_of_pane(cx, pane) == nil and state.ownership_cycle(anchor, pane) == nil then
					if found ~= nil then
						return nil, "multiple unowned agents in this tab; pass --pane <id>"
					end
					found = pane
				end
			end
		end
		if found ~= nil then
			return found, nil
		end
	end
	return select_worker(cx, anchor, req.target_pane, req.cwd)
end

type Relocation = { id: number, position: number?, dispatched: boolean }

-- The one validated path that moves a queued item (to another slot or pane) and promotes it when the
-- destination can take it now. `owner` is the supervisor that adopts an unowned destination; nil moves the
-- item without creating any ownership edge.
local function relocate_queued(
	cx: WindowCx,
	id: number,
	pane: number,
	dst: number,
	to_pos: number?,
	owner: number?
): (Relocation?, string?)
	local destination: AgentBlock? = nil
	local adopts = false
	if dst ~= pane then
		destination = find_agent_info(cx, dst)
		if not destination or destination.state == "waiting_input" or destination.state == "exited" then
			return nil, "destination pane is " .. (if destination then destination.state else "not an agent")
		end
		adopts = owner ~= nil and state.owner_of_pane(cx, dst) == nil
		if adopts then
			local cycle = state.ownership_cycle(owner :: number, dst)
			if cycle then
				return nil, cycle
			end
		end
	end
	local item, err, position = dispatches.move(id, to_pos, dst, pane)
	if not item then
		return nil, err
	end
	local dispatched = false
	if destination then
		if adopts then
			state.bind_wingman(owner :: number, dst)
		end
		if destination.state == "idle" and not has_pending_dispatch(dst) then
			dispatched = promote_next_queued(cx, dst) == item.id
			if not dispatched then
				local _, current_position = dispatches.find(item.id)
				if not current_position then
					return nil, "moved queue item could not be dispatched"
				end
				position = current_position
			end
		end
	end
	ensure_watchdog()
	return { id = item.id, position = position, dispatched = dispatched }, nil
end

local function queue_request(cx: WindowCx, anchor: number?, req: any): any
	if not anchor then
		return { ok = false, error = "missing anchor_pane" }
	end
	local legacy = req.op == "unqueue"
	local action = if legacy then "cancel" else req.action
	if action ~= "list" and action ~= "edit" and action ~= "cancel" and action ~= "move" and action ~= "reorder" then
		return { ok = false, error = "unknown queue action" }
	end
	local function cwd_matches(pane: number): boolean
		if not supplied(req.cwd) then
			return true
		end
		local info = cx.session:pane(pane)
		return info ~= nil and info.cwd == req.cwd
	end
	if action == "list" and req.all == true then
		if supplied(req.target_pane) then
			return { ok = false, error = "queue list --all cannot select a pane" }
		end
		local panes = state.workers_of_owner(cx, anchor)
		local matching: { number } = {}
		for _, pane in panes do
			if cwd_matches(pane) then
				table.insert(matching, pane)
			end
		end
		return { ok = true, items = tern.json.array(dispatches.list_panes(matching)) }
	end

	local id = if supplied(req.id) then positive_integer(req.id) else nil
	if (supplied(req.id) or action == "edit" or action == "move") and id == nil then
		return { ok = false, error = "queue id must be a positive integer" }
	end
	local order = req.ordered_ids
	if action == "reorder" and type(order) ~= "table" then
		return { ok = false, error = "ordered_ids must be an array of queue IDs" }
	end
	local first_id = if action == "reorder" and not supplied(req.target_pane) and type(order[1]) == "number"
		then order[1] else id
	local pane, source_error = queue_source(cx, anchor, req, first_id)
	if not pane then
		return { ok = false, error = source_error }
	end
	local access_error = queue_access(cx, anchor, pane)
	if access_error then
		return { ok = false, error = access_error }
	end
	if (not legacy or id ~= nil) and not cwd_matches(pane) then
		return { ok = false, error = "queue pane does not match cwd" }
	elseif action == "list" then
		return { ok = true, pane = pane, items = tern.json.array(dispatches.list(pane)) }
	elseif action == "edit" then
		if type(req.prompt) ~= "string" then
			return { ok = false, error = "queue prompt is empty" }
		end
		local item, err, position = dispatches.edit(id :: number, req.prompt, pane)
		return if item then { ok = true, pane = pane, id = item.id, position = position, prompt = item.prompt }
			else { ok = false, error = err }
	elseif action == "cancel" then
		local position = if supplied(req.position) then positive_integer(req.position) else nil
		if supplied(req.position) and position == nil then
			return { ok = false, error = "queue position must be a positive integer" }
		end
		local selectors = (if id then 1 else 0) + (if position then 1 else 0) + (if req.all == true then 1 else 0)
		if selectors > 1 or (not legacy and selectors ~= 1) then
			return { ok = false, error = "choose one of queue id, position, or all" }
		end
		if legacy and id == nil and dispatches.count(pane) == 0 then
			return { ok = true, pane = pane, cancelled = 0, remaining = 0 }
		end
		local cancelled, err = cancel_queued(pane, position, id)
		return if err then { ok = false, error = err }
			else { ok = true, pane = pane, cancelled = cancelled, remaining = dispatches.count(pane) }
	elseif action == "reorder" then
		-- Positional pane selection follows the IDs and is only unambiguous if it is not in the permutation.
		local last = order[#order]
		if req.allow_trailing_pane == true and not supplied(req.target_pane) and #order == dispatches.count(pane) + 1
			and last == pane and dispatches.find(last) == nil then
			local ids = table.clone(order)
			table.remove(ids)
			order = ids
		end
		local ok, err = dispatches.reorder(pane, order)
		return if ok then { ok = true, pane = pane, items = tern.json.array(dispatches.list(pane)) }
			else { ok = false, error = err }
	end

	local to_pos = if supplied(req.to_pos) then positive_integer(req.to_pos) else nil
	local dst = if supplied(req.to_pane) then positive_integer(req.to_pane) else pane
	if not dst or (supplied(req.to_pos) and not to_pos) then
		return { ok = false, error = "destination pane and position must be positive integers" }
	end
	if dst ~= pane then
		local err = queue_access(cx, anchor, dst)
		if err then
			return { ok = false, error = err }
		end
	end
	local moved, move_error = relocate_queued(cx, id :: number, pane, dst, to_pos, anchor)
	if not moved then
		return { ok = false, error = move_error }
	end
	return {
		ok = true, id = moved.id, from_pane = pane, to_pane = dst, pane = dst,
		position = moved.position, dispatched = moved.dispatched,
	}
end

local TARGETED_OPS = {
	pip = true, dock = true, park = true, unpark = true, interrupt = true,
	retry = true, stop = true, transcript = true, surface = true, event = true, await = true,
}

local function handle_request(cx: WindowCx, cid: number, req: any)
	local op = req.op
	local anchor = tonumber(req.anchor_pane)
	if op == "queue" or op == "unqueue" then
		send_mux(cid, queue_request(cx, anchor, req), false)
		return
	end
	local target: number? = nil
	if TARGETED_OPS[op] then
		local err: string?
		target, err = select_worker(cx, anchor, req.target_pane, req.cwd)
		if not target then
			send_mux(cid, { ok = false, error = err }, false)
			return
		end
		if anchor and (op == "pip" or op == "dock" or op == "retry" or op == "await" or (op == "event" and req.rearm ~= false)) then
			local cycle = state.ownership_cycle(anchor, target)
			if cycle then
				send_mux(cid, { ok = false, error = cycle }, false)
				return
			end
		end
	end

	if op == "status" then
		seed_inflight_unsolicited_turns(cx)
		local my_tab = if anchor then cx.session:tab_of(anchor) else nil
		local bound_panes = if anchor then state.workers_of_owner(cx, anchor) else {}
		local my_owner = if anchor then state.owner_of_pane(cx, anchor) else nil
		local floats = tern.json.array()
		if my_tab then
			local lay = cx.session:layout(my_tab)
			if lay and lay.floats then
				floats = tern.json.array(lay.floats)
			end
		end
		local out = {}
		for _, a in ipairs(cx.agents:list()) do
			local info = cx.session:pane(a.pane)
			local atab = if info then info.tab else nil
			local owner = state.owner_of_pane(cx, a.pane)
			local items = dispatches.compact(a.pane)
			local cb_q = queued_callbacks[a.pane]
			local cb_q_count = if cb_q then #cb_q else 0
			table.insert(out, {
				pane = a.pane,
				tab = atab,
				same_tab = (my_tab ~= nil and atab == my_tab),
				is_self = (anchor ~= nil and a.pane == anchor),
				is_bound_to_me = anchor ~= nil and owner == anchor,
				parked = info ~= nil and info.parked == true,
				floating = info ~= nil and info.floating == true,
				bound_owner = owner,
				auto_callback = if owner ~= nil then state.is_auto_callback_enabled(owner) else state.is_auto_callback_enabled(a.pane),
				queued_count = #items,
				queued_preview = if items[1] then items[1].preview else nil,
				queued_items = tern.json.array(items),
				queued_callbacks_count = cb_q_count,
				cwd = a.cwd,
				state = a.state,
				model = if (a.model :: any) ~= tern.json.null then a.model else nil,
				command = if (a.command :: any) ~= tern.json.null then a.command else nil,
				last_message = if (a.last_message :: any) ~= tern.json.null then a.last_message else nil,
				delivery_error = if (a.delivery_error :: any) ~= tern.json.null then a.delivery_error else nil,
			})
		end
		send_mux(cid, {
			ok = true,
			window_key = cx:window_key(),
			anchor_tab = my_tab,
			bound_panes = tern.json.array(bound_panes),
			bound_pane = if #bound_panes == 1 then bound_panes[1] else nil,
			owner_pane = my_owner,
			auto_callback = state.is_auto_callback_enabled(anchor),
			default_auto_callback = state.default_auto_callback(),
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
		if target_owner ~= nil and #state.workers_of_owner(cx, target_owner) == 0 then
			local maybe_owner = state.owner_of_pane(cx, target_owner)
			if maybe_owner ~= nil then
				target_owner = maybe_owner
			end
		end
		if mode == "on" or mode == "off" then
			local val = (mode == "on")
			state.set_callback(if scope == "global" then nil else target_owner, val)
		elseif mode == "reset" then
			if scope == "global" then
				state.reset_callbacks()
			else
				state.reset_callback(target_owner)
			end
		end
		send_mux(cid, {
			ok = true,
			owner_pane = target_owner,
			enabled = state.is_auto_callback_enabled(target_owner),
			default_enabled = state.default_auto_callback(),
		}, false)
		return
	end

	if op == "pip" or op == "dock" or op == "park" or op == "unpark" then
		local tp = target :: number
		local over = state.owner_of_pane(cx, tp) or anchor
		local ok: boolean, err: string?
		if op == "pip" then
			ok, err = float_worker(cx, tp, over, corner_of(req.corner))
		elseif op == "dock" then
			local d: Dir? = if req.dir == "left" or req.dir == "right" or req.dir == "up" or req.dir == "down"
				then req.dir
				else nil
			ok, err = dock_worker(cx, tp, over, d)
		elseif op == "park" then
			ok, err = park_pane(cx, tp)
		else
			ok, err = unpark_pane(cx, tp)
		end
		if ok and anchor and not state.owner_of_pane(cx, tp) and (op == "pip" or op == "dock") then
			state.bind_wingman(anchor, tp)
		end
		send_mux(cid, { ok = ok, pane = tp, error = err }, false)
		return
	end

	if op == "interrupt" then
		local tp = target :: number
		local ok_i, err_i = interrupt_pane(cx, tp)
		send_mux(cid, { ok = ok_i, error = err_i }, false)
		return
	end

	if op == "retry" then
		local tp = target :: number
		local ok_r, err_r, busy_state = retry_pane(cx, tp)
		if not ok_r then
			send_mux(cid, { ok = false, pane = tp, state = busy_state, error = err_r }, false)
			return
		end
		if anchor and not state.owner_of_pane(cx, tp) then
			state.bind_wingman(anchor, tp)
		end
		if req.async_callback == true then
			if anchor then
				state.arm_callback(anchor)
			end
			unsolicited_working[tp] = true
			reported_in_turn[tp] = false
			send_mux(cid, { ok = true, async_callback = true, pane = tp, retried = true }, false)
		else
			send_mux(cid, { _ack = true, pane = tp }, true)
			register_waiter(tp, cid)
		end
		return
	end

	if op == "stop" then
		local tp = target :: number
		local ok, err = stop_worker(cx, tp)
		send_mux(cid, { ok = ok, pane = tp, error = err }, false)
		return
	end

	if op == "transcript" then
		local tp = target :: number
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
		local tp = target :: number
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
			i_root, i_role = tsp.find_interactive_root(tree)
			if root == nil then
				root = i_root
			end
		end
		if want_as == "table" then
			local out_tree = tree
			if root ~= nil and type(tree) == "table" then
				local sub = tsp.find_node_by_id(tree, tostring(root))
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
				local sub = tsp.find_node_by_id(tree, tostring(root))
				if sub ~= nil then
					tsp.format_tsp_subtree(sub, "", lines, 0)
				end
			else
				for _, region in ipairs({ "layer", "main", "dock" }) do
					if type(tree[region]) == "table" then
						tsp.format_tsp_subtree(tree[region], "", lines, 0)
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
		local tp = target :: number
		local events: any = if type(req.events) == "table" then req.events elseif type(req.ev) == "table" then { req.ev } else {}
		local results = {}
		local all_ok = #events > 0
		for i, ev in ipairs(events) do
			local ok_e, res_e = pcall(function(): any
				cx.session:event(tp :: number, ev)
				return nil
			end)
			all_ok = all_ok and ok_e
			table.insert(results, { index = i, ok = ok_e, error = if ok_e then nil else tostring(res_e), result = if ok_e then res_e else nil })
		end
		if req.rearm ~= false then
			state.clear_waiting(tp)
			if anchor and not state.owner_of_pane(cx, tp) then
				state.bind_wingman(anchor, tp)
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
		local tp = target :: number
		if anchor and not state.owner_of_pane(cx, tp) then
			state.bind_wingman(anchor, tp)
		end
		send_mux(cid, { _ack = true, pane = tp }, true)
		local ainfo = find_agent_info(cx, tp)
		if not ainfo then
			if cx.session:pane(tp) == nil then
				send_mux(cid, { ok = false, pane = tp, status = "closed", error = "Agent pane disappeared", last_message = "", transcript = tern.json.array() }, false)
				return
			end
			register_waiter(tp, cid)
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
		register_waiter(tp, cid)
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
		local prompt = req.prompt
		if type(prompt) ~= "string" or not string.find(prompt, "%S") then
			send_mux(cid, { ok = false, error = "dispatch prompt is empty" }, false)
			return
		end
		local position = if supplied(req.position) then positive_integer(req.position) else nil
		if supplied(req.position) and position == nil then
			send_mux(cid, { ok = false, error = "queue position must be a positive integer" }, false)
			return
		end
		local form: WorkerLayout? = nil
		local requested = req.layout
		local corner: Corner? = corner_of(req.pip_corner)
		local placement_corner: Corner = if corner then corner else "br"
		if requested == nil or requested == tern.json.null then
			if corner then
				form = "pip" -- Legacy clients sent only pip_corner.
			end
		elseif requested == "split" or requested == "down" or requested == "pip" or requested == "tab" or requested == "park" then
			form = requested
		else
			send_mux(cid, { ok = false, error = "invalid wingman layout" }, false)
			return
		end
		local reset_new = req.reset_new == true
		local target_pane: number? = nil
		if reset_new or (req.target_pane ~= nil and req.target_pane ~= tern.json.null) then
			local err: string?
			target_pane, err = select_worker(cx, anchor, req.target_pane, req.cwd)
			if not target_pane then
				send_mux(cid, { ok = false, error = err }, false)
				return
			end
			local cycle = state.ownership_cycle(anchor, target_pane)
			if cycle then
				send_mux(cid, { ok = false, error = cycle }, false)
				return
			end
			local owner = state.owner_of_pane(cx, target_pane)
			if reset_new and owner ~= anchor then
				send_mux(cid, { ok = false, error = "can only replace a wingman bound to the caller" }, false)
				return
			elseif owner and owner ~= anchor then
				send_mux(cid, { ok = false, error = "target wingman is bound to pane " .. tostring(owner) }, false)
				return
			end
		end

		local command = req.command
		if (not target_pane or reset_new) and (type(command) ~= "string" or command == "") then
			send_mux(cid, { ok = false, error = "missing worker launch command" }, false)
			return
		end
		if target_pane and reset_new then
			local ok, err = stop_worker(cx, target_pane)
			if not ok then
				send_mux(cid, { ok = false, error = "could not replace wingman: " .. tostring(err) }, false)
				return
			end
			target_pane = nil
		end

		local async_cb = req.async_callback == true
		local agent = if target_pane then find_agent_info(cx, target_pane) else nil
		if agent and agent.state == "waiting_input" then
			send_mux(cid, {
				ok = false,
				status = "waiting_input",
				pane = target_pane,
				error = "target wingman pane is waiting_input; inspect via `wingman surface` and answer/cancel via `wingman event` instead of `send`",
			}, false)
			return
		end
		if agent and agent.state == "exited" then
			send_mux(cid, { ok = false, pane = target_pane, status = "exited", error = "Agent process exited" }, false)
			return
		end
		local busy = target_pane ~= nil and (has_pending_dispatch(target_pane) or dispatches.count(target_pane) > 0
			or (agent ~= nil and agent.state == "working"))
		if busy and req.queue == false then
			send_mux(cid, { ok = false, error = "target agent pane is currently busy" }, false)
			return
		end
		if busy and position and target_pane and position > dispatches.count(target_pane) + 1 then
			send_mux(cid, { ok = false, error = string.format("queue position %d out of range (1..%d)", position, dispatches.count(target_pane) + 1) }, false)
			return
		end

		local new_worker = target_pane == nil
		local pane: number
		if target_pane then
			pane = target_pane
			if form then
				local ok, err = place_worker(cx, pane, anchor, form, placement_corner)
				if not ok then
					send_mux(cid, { ok = false, error = err or ("could not place wingman in " .. form) }, false)
					return
				end
			end
		else
			local spawned, err = spawn_worker(cx, anchor, form or "split", tostring(req.cwd or ""), command, placement_corner)
			if not spawned then
				send_mux(cid, { ok = false, error = err }, false)
				return
			end
			pane = spawned
		end

		local queued_item: Queue.Item?
		local queued_position: number?
		if busy then
			load_dispatch_ids(cx)
			local err: string?
			queued_item, err, queued_position = dispatches.enqueue(pane, { cid = if async_cb then nil else cid, anchor = anchor, prompt = prompt }, position)
			if not queued_item then
				send_mux(cid, { ok = false, error = err }, false)
				return
			end
		else
			-- Tern queues the prompt until the composer is sendable, including on a freshly parked pane.
			local ok, err = ask_worker(cx, pane, prompt)
			if not ok then
				if new_worker then
					cx.layout:close(pane)
				end
				send_mux(cid, { ok = false, error = "cx.agents:ask failed: " .. tostring(err) }, false)
				return
			end
		end
		state.bind_wingman(anchor, pane)

		if async_cb then
			state.arm_callback(anchor)
		elseif type(req.auto_callback) == "boolean" then
			state.set_callback(anchor, req.auto_callback)
		end

		if queued_item then
			if async_cb then
				send_mux(cid, { ok = true, async_callback = true, pane = pane, queued = true, queue_id = queued_item.id, position = queued_position }, false)
			else
				send_mux(cid, { _ack = true, pane = pane, queued = true, queue_id = queued_item.id, position = queued_position }, true)
			end
			ensure_watchdog()
		elseif async_cb then
			unsolicited_working[pane] = true
			reported_in_turn[pane] = false
			send_mux(cid, { ok = true, async_callback = true, pane = pane, queued = false, position = 0 }, false)
		else
			send_mux(cid, { _ack = true, pane = pane }, true)
			register_waiter(pane, cid)
		end
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
		notify_radar()
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
	local ok_h, err_h = pcall(function(): any
		handle_request(cx, cid, req)
		return nil
	end)
	if not ok_h then
		send_mux(cid, { ok = false, error = tostring(err_h) }, false)
	end
	notify_radar()
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
		local state_label = if state.toggle_default_callback() then "enabled" else "disabled"
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
		state.load()
		ensure_mux()
	end
	if cx then
		seed_inflight_unsolicited_turns(cx)
	end
end

tern.on("window_start", start)
tern.timer(0, start)

local function enqueue_prompt(cx: WindowCx, pane: number, prompt: string): (boolean, string?, boolean?, number?, number?)
	if not string.find(prompt, "%S") then
		return false, "prompt is empty"
	end
	local agent = find_agent_info(cx, pane)
	if agent == nil or cx.session:pane(pane) == nil then
		return false, "agent pane is no longer live"
	elseif agent.state == "waiting_input" or agent.state == "exited" then
		return false, "agent is " .. agent.state
	end
	if agent.state == "working" or has_pending_dispatch(pane) or dispatches.count(pane) > 0 then
		local loaded, load_error = pcall(function(): any
			load_dispatch_ids(cx)
			return nil
		end)
		if not loaded then
			return false, tostring(load_error)
		end
		local item, err, position = dispatches.enqueue(pane, { anchor = state.owner_of_pane(cx, pane) or pane, prompt = prompt })
		if item == nil then
			return false, err
		end
		ensure_watchdog()
		notify_radar()
		return true, nil, true, item.id, position
	end
	local ok, err = ask_worker(cx, pane, prompt)
	if not ok then
		return false, tostring(err)
	end
	unsolicited_working[pane] = true
	reported_in_turn[pane] = false
	notify_radar()
	return true, nil, false
end

-- Every queued prompt on a live pane, sorted by pane then slot.
local function all_queued(cx: WindowCx): { Queue.Snapshot }
	local live: { number } = {}
	for _, pane in dispatches.panes() do
		if cx.session:pane(pane) ~= nil then
			table.insert(live, pane)
		end
	end
	return dispatches.list_panes(live)
end

-- A user's explicit move from the panel. The window is the authority here, so no anchor pane is needed; the
-- shared relocation adopts an unowned destination only for an owned source, and never invents an owner
-- for a queue nobody owns.
local function move_queued(cx: WindowCx, id: number, to_pane: number): (boolean, string?, boolean?)
	local pane = dispatches.find(id)
	if pane == nil then
		return false, "queue item " .. id .. " is no longer queued"
	elseif pane == to_pane then
		return false, "queue item is already on pane " .. pane
	end
	local moved, err = relocate_queued(cx, id, pane, to_pane, nil, state.owner_of_pane(cx, pane))
	if not moved then
		return false, err
	end
	notify_radar()
	return true, nil, moved.dispatched
end

local function mutate_queued(action: "edit" | "top" | "cancel", id: number, prompt: string?): (boolean, string?)
	local item: Queue.Item?
	local err: string?
	if action == "edit" then
		item, err = dispatches.edit(id, prompt or "")
	elseif action == "top" then
		item, err = dispatches.move(id, 1)
	else
		local pane = dispatches.find(id)
		if pane == nil then
			return false, "queue item " .. id .. " is no longer queued"
		end
		local removed, why = cancel_queued(pane, nil, id)
		if removed == 0 then
			return false, why
		end
		notify_radar()
		return true, nil
	end
	if item == nil then
		return false, err
	end
	notify_radar()
	return true, nil
end

-- The live panel's narrow view of this control plane: read-only accessors plus the cores the RPC ops use.
if radar_loaded then
	local ok_attach, err_attach = pcall(function(): any
		radar.attach({
			all_queued = all_queued,
			move_queued = move_queued,
			owners = state.owners,
			can_pip = can_pip,
			queue_items = function(pane: number): { Queue.Compact }
				return dispatches.compact(pane)
			end,
			queue_prompt = function(id: number): string?
				local _, _, item = dispatches.find(id)
				return if item then item.prompt else nil
			end,
			enqueue_prompt = enqueue_prompt,
			edit_queued = function(id: number, prompt: string): (boolean, string?)
				return mutate_queued("edit", id, prompt)
			end,
			promote_queued = function(id: number): (boolean, string?)
				return mutate_queued("top", id, nil)
			end,
			cancel_queued_id = function(id: number): (boolean, string?)
				return mutate_queued("cancel", id, nil)
			end,
			queued_dispatches = function(pane: number): number
				return dispatches.count(pane)
			end,
			queued_callbacks = function(pane: number): number
				local q = queued_callbacks[pane]
				return if q then #q else 0
			end,
			notified_waiting = state.waiting_key,
			-- Fault keys are `fault:<surface node>:<summary>`, or `fault:<reason>` without a surface
			-- (deliver_fault_if_needed); no surface is read here.
			fault = function(pane: number): string?
				local key = state.waiting_key(pane)
				if key == nil or string.sub(key, 1, 6) ~= "fault:" then
					return nil
				end
				local rest = string.sub(key, 7)
				return string.match(rest, "^[^:]*:(.+)$") or rest
			end,
			pip = function(cx: WindowCx, pane: number): (boolean, string?)
				return float_worker(cx, pane, state.owner_of_pane(cx, pane), nil)
			end,
			dock = function(cx: WindowCx, pane: number): (boolean, string?)
				return dock_worker(cx, pane, state.owner_of_pane(cx, pane), nil)
			end,
			park = park_pane,
			unpark = unpark_pane,
			interrupt = interrupt_pane,
			retry = function(cx: WindowCx, pane: number): (boolean, string?)
				local ok_r, err_r = retry_pane(cx, pane)
				if ok_r then
					-- As `retry --async`: the retried turn reports back to its bound owner when it ends.
					unsolicited_working[pane] = true
					reported_in_turn[pane] = false
				end
				return ok_r, err_r
			end,
			unqueue = function(_cx: WindowCx, pane: number): number
				return (cancel_queued(pane, nil))
			end,
		})
		return nil
	end)
	if not ok_attach then
		tern.log.error("wingman: radar.attach failed:", tostring(err_attach))
	end
end
