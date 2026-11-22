--!strict
-- Wingman persistent control-plane state: ownership graph, escalation dedup and auto-callback policy.

local KV_OWNERS = "owners_v1"
local KV_LEGACY_BINDINGS = "bindings_v1"
local KV_CALLBACK_CFG = "auto_callback_v1"
local KV_WAITING = "notified_waiting_v1"

export type Kv = {
	get: (key: string) -> any,
	set: (key: string, value: any) -> (),
}

export type Log = {
	warn: (...any) -> (),
}

export type Ports = {
	kv: Kv,
	log: Log,
	-- Called after ownership or escalation state was persisted (even if the write failed).
	notify: () -> (),
}

export type State = {
	-- Ownership graph: each worker has one owner; an owner supervises any number of workers.
	ownership_cycle: (anchor: number, worker: number) -> string?,
	bind_wingman: (anchor: number, worker: number) -> string?,
	unbind_pane: (pane: number) -> (),
	workers_of_owner: (cx: WindowCx, anchor: number) -> { number },
	owner_of_pane: (cx: WindowCx, pane: number) -> number?,
	raw_owner: (pane: number) -> number?,
	owners: () -> { [number]: number },
	-- Escalation dedup (`waiting_input` / `fault`), keyed by worker pane.
	waiting_key: (pane: number) -> string?,
	record_waiting: (pane: number, key: string) -> boolean,
	clear_waiting: (pane: number) -> (),
	-- Auto-callback policy: global default plus per-owner overrides.
	is_auto_callback_enabled: (owner: number?) -> boolean,
	default_auto_callback: () -> boolean,
	set_callback: (owner: number?, value: boolean) -> (),
	arm_callback: (owner: number) -> (),
	toggle_default_callback: () -> boolean,
	reset_callbacks: () -> (),
	reset_callback: (owner: number?) -> (),
	-- Lifecycle.
	load: () -> (),
	prune_notifications: (cx: WindowCx) -> (),
}

local function new(ports: Ports): State
	local kv, log, notify = ports.kv, ports.log, ports.notify

	local owners: { [number]: number } = {}
	local notified_waiting: { [number]: string } = {}
	local default_auto_callback = true
	local owner_auto_callback: { [number]: boolean } = {}

	local function ownership_cycle(anchor: number, worker: number): string?
		local ancestor: number? = anchor
		while ancestor ~= nil do
			if ancestor == worker then
				return string.format("refusing to bind pane %d to pane %d: ownership cycle", worker, anchor)
			end
			ancestor = owners[ancestor]
		end
		return nil
	end

	local function save_owners(): boolean
		local serialized: { [string]: number } = {}
		for worker, owner in owners do
			serialized[tostring(worker)] = owner
		end
		local ok, err = pcall(function(): any
			kv.set(KV_OWNERS, serialized)
			return nil
		end)
		if not ok then
			log.warn("wingman: could not persist owners:", tostring(err))
		end
		notify()
		return ok
	end

	local function load_owners()
		local ok, raw = pcall(kv.get, KV_OWNERS)
		if not ok then
			log.warn("wingman: could not read owners:", tostring(raw))
			return
		end
		local legacy = raw == nil
		if legacy then
			ok, raw = pcall(kv.get, KV_LEGACY_BINDINGS)
			if not ok then
				log.warn("wingman: could not read legacy bindings:", tostring(raw))
				return
			end
		end
		if type(raw) == "table" then
			local candidates: { [number]: number } = {}
			local workers: { number } = {}
			for k, v in raw do
				local key, value = tonumber(k), tonumber(v)
				if key and value then
					local worker, owner = if legacy then value else key, if legacy then key else value
					local previous = candidates[worker]
					if previous == nil then
						table.insert(workers, worker)
						candidates[worker] = owner
					elseif owner < previous then
						candidates[worker] = owner
					end
				end
			end
			-- Older versions could persist cycles. Keep valid edges in stable pane order.
			table.sort(workers)
			local repaired = false
			for _, worker in workers do
				local owner = candidates[worker]
				if ownership_cycle(owner, worker) then
					repaired = true
				else
					owners[worker] = owner
				end
			end
			if (legacy or repaired) and save_owners() and legacy then
				pcall(kv.set, KV_LEGACY_BINDINGS, nil)
			end
		end
	end

	local function save_callback_cfg()
		local overrides: { [string]: boolean } = {}
		for aid, val in pairs(owner_auto_callback) do
			overrides[tostring(aid)] = val
		end
		pcall(function()
			kv.set(KV_CALLBACK_CFG, {
				default = default_auto_callback,
				owners = overrides,
			})
		end)
	end

	local function load_callback_cfg()
		local ok, raw = pcall(kv.get, KV_CALLBACK_CFG)
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
			kv.set(KV_WAITING, if next(ser) ~= nil then ser else nil)
		end)
		notify()
	end

	local function load_waiting()
		local ok, raw = pcall(kv.get, KV_WAITING)
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

	local function prune_notifications(cx: WindowCx)
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

	local function workers_of_owner(cx: WindowCx, anchor: number): { number }
		local workers: { number } = {}
		for worker, owner in owners do
			if owner == anchor and cx.session:pane(worker) ~= nil then
				table.insert(workers, worker)
			end
		end
		table.sort(workers)
		return workers
	end

	local function owner_of_pane(cx: WindowCx, pane_id: number): number?
		local owner = owners[pane_id]
		return if owner ~= nil and cx.session:pane(owner) ~= nil then owner else nil
	end

	-- Callers still preflight existing panes before changing layout or sending a turn; the guard here
	-- keeps the graph acyclic even if a caller forgets. Returns the refusal, nil when bound.
	local function bind_wingman(anchor: number, worker: number): string?
		if owners[worker] == anchor then
			return nil
		end
		local refusal = ownership_cycle(anchor, worker)
		if refusal then
			return refusal
		end
		owners[worker] = anchor
		save_owners()
		return nil
	end

	-- Drops every edge touching a closed pane; true when the graph changed.
	local function prune_bindings(closed_pane: number): boolean
		local dirty = owners[closed_pane] ~= nil
		owners[closed_pane] = nil
		for worker, owner in owners do
			if owner == closed_pane then
				owners[worker] = nil
				dirty = true
			end
		end
		return dirty
	end

	local function unbind_pane(pane_id: number)
		if prune_bindings(pane_id) then
			save_owners()
		end
		if owner_auto_callback[pane_id] ~= nil then
			owner_auto_callback[pane_id] = nil
			save_callback_cfg()
		end
	end

	-- True when the key is new for the pane (recorded and persisted); false when it was already delivered.
	local function record_waiting(pane_id: number, key: string): boolean
		if notified_waiting[pane_id] == key then
			return false
		end
		notified_waiting[pane_id] = key
		save_waiting()
		return true
	end

	-- A nil owner addresses the global default.
	local function set_callback(owner: number?, value: boolean)
		if owner == nil then
			default_auto_callback = value
		else
			owner_auto_callback[owner] = value
		end
		save_callback_cfg()
	end

	-- A worker turn that must report back re-enables a callback the owner had switched off.
	local function arm_callback(owner: number)
		if owner_auto_callback[owner] == false then
			owner_auto_callback[owner] = true
			save_callback_cfg()
		end
	end

	local function toggle_default_callback(): boolean
		default_auto_callback = not default_auto_callback
		save_callback_cfg()
		return default_auto_callback
	end

	local function reset_callbacks()
		default_auto_callback = true
		table.clear(owner_auto_callback)
		save_callback_cfg()
	end

	-- A nil owner only re-persists the current policy.
	local function reset_callback(owner: number?)
		if owner ~= nil then
			owner_auto_callback[owner] = nil
		end
		save_callback_cfg()
	end

	local function load()
		load_owners()
		load_callback_cfg()
		load_waiting()
	end

	return {
		ownership_cycle = ownership_cycle,
		bind_wingman = bind_wingman,
		unbind_pane = unbind_pane,
		workers_of_owner = workers_of_owner,
		owner_of_pane = owner_of_pane,
		raw_owner = function(pane_id: number): number?
			return owners[pane_id]
		end,
		owners = function(): { [number]: number }
			return table.clone(owners)
		end,
		waiting_key = function(pane_id: number): string?
			return notified_waiting[pane_id]
		end,
		record_waiting = record_waiting,
		clear_waiting = clear_waiting,
		is_auto_callback_enabled = is_auto_callback_enabled,
		default_auto_callback = function(): boolean
			return default_auto_callback
		end,
		set_callback = set_callback,
		arm_callback = arm_callback,
		toggle_default_callback = toggle_default_callback,
		reset_callbacks = reset_callbacks,
		reset_callback = reset_callback,
		load = load,
		prune_notifications = prune_notifications,
	}
end

return { new = new }
