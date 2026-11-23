--!strict
-- Wingman dispatch queue: ordered per-pane prompt lists with stable item ids.
-- Pure state: no requires, no globals, no I/O. Every operation validates before it mutates, and every
-- item handed out is frozen, so a caller can neither corrupt the queue nor see a later edit in place.

-- Status previews keep the first 120 bytes of a prompt, cut on a UTF-8 character boundary.
local PREVIEW_BYTES = 120

export type Item = {
	id: number,
	pane: number,
	anchor: number,
	-- Mux client blocked on this task; nil for async dispatches.
	cid: number?,
	prompt: string,
	enqueued_ms: number,
}

-- What a caller supplies for a new task; the queue assigns id, pane and time.
export type Draft = {
	anchor: number,
	cid: number?,
	prompt: string,
}

-- JSON-ready copy of an item with its current 1-based slot.
export type Snapshot = {
	id: number,
	pane: number,
	position: number,
	anchor: number,
	waiting_caller: boolean,
	enqueued_ms: number,
	prompt: string,
	preview: string,
}

-- Status line for one queued task.
export type Compact = {
	id: number,
	position: number,
	preview: string,
}

-- Durable id reservation: (true) to proceed, (false, reason) to refuse the enqueue.
export type Reserve = (id: number) -> (boolean, string?)

export type Queue = {
	enqueue: (pane: number, draft: Draft, position: number?) -> (Item?, string?, number?),
	find: (id: number, pane: number?) -> (number?, number?, Item?),
	edit: (id: number, prompt: string, pane: number?) -> (Item?, string?, number?),
	cancel_by_id: (id: number, pane: number?) -> (Item?, string?),
	cancel_at: (pane: number, position: number?) -> ({ Item }, string?),
	clear_pane: (pane: number) -> { Item },
	drop_cid: (cid: number) -> { Item },
	pop_next: (pane: number) -> Item?,
	move: (id: number, to_pos: number?, to_pane: number?, pane: number?) -> (Item?, string?, number?),
	reorder: (pane: number, ordered_ids: { number }) -> (boolean, string?),
	list: (pane: number) -> { Snapshot },
	list_panes: (panes: { number }) -> { Snapshot },
	compact: (pane: number) -> { Compact },
	count: (pane: number) -> number,
	panes: () -> { number },
	has_any: () -> boolean,
}

-- Doubles are exact integers only up to 2^53; beyond that `id + 1` can equal `id` and ids would repeat.
local MAX_SAFE_INTEGER = 2 ^ 53 - 1

local function is_integer(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER
end

local function prompt_error(prompt: any): string?
	if type(prompt) ~= "string" or not string.find(prompt, "%S") then
		return "queued prompt is empty"
	end
	return nil
end

-- `slots` is how many positions the destination offers: 1..slots, so 0 means an empty queue.
local function slot_error(position: any, slots: number): string?
	if not is_integer(position) then
		return "queue position must be an integer"
	end
	if position < 1 or position > slots then
		local range = if slots == 0 then "queue is empty" else "1.." .. slots
		return string.format("queue position %s out of range (%s)", tostring(position), range)
	end
	return nil
end

local function preview(prompt: string): string
	if #prompt <= PREVIEW_BYTES then
		return prompt
	end
	local cut = PREVIEW_BYTES
	-- A continuation byte (0x80..0xBF) first past the cut would split a character: back up to its lead byte.
	while cut > 0 do
		local byte = string.byte(prompt, cut + 1)
		if byte < 0x80 or byte >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(prompt, 1, cut)
end

local function make_item(
	id: number,
	pane: number,
	anchor: number,
	cid: number?,
	prompt: string,
	enqueued_ms: number
): Item
	return table.freeze({
		id = id,
		pane = pane,
		anchor = anchor,
		cid = cid,
		prompt = prompt,
		enqueued_ms = enqueued_ms,
	})
end

local function snapshot(item: Item, position: number): Snapshot
	return {
		id = item.id,
		pane = item.pane,
		position = position,
		anchor = item.anchor,
		waiting_caller = item.cid ~= nil,
		enqueued_ms = item.enqueued_ms,
		prompt = item.prompt,
		preview = preview(item.prompt),
	}
end

-- `last_id` is the last id already issued (by a previous window incarnation); the first new id follows it.
local function new(now: () -> number, last_id: number?, reserve_id: Reserve?): Queue
	if last_id ~= nil and (not is_integer(last_id) or last_id < 0) then
		error("queue: last_id must be an integer from 0 to 2^53 - 1", 2)
	end
	local next_id: number = (last_id or 0) + 1
	-- Invariant: only non-empty lists are stored; each item's `pane` is the key of its list.
	local queues: { [number]: { Item } } = {}

	local function find_in(list: { Item }, id: number): (number?, Item?)
		for position, item in ipairs(list) do
			if item.id == id then
				return position, item
			end
		end
		return nil, nil
	end

	local function locate(id: number, pane: number?): (number?, number?, Item?)
		if pane ~= nil then
			local list = queues[pane]
			if list ~= nil then
				local position, item = find_in(list, id)
				if item ~= nil then
					return pane, position, item
				end
			end
			return nil, nil, nil
		end
		for owner, list in queues do
			local position, item = find_in(list, id)
			if item ~= nil then
				return owner, position, item
			end
		end
		return nil, nil, nil
	end

	local function missing(id: number, pane: number?): string
		if pane ~= nil then
			return string.format("queued item %s not found on pane %s", tostring(id), tostring(pane))
		end
		return string.format("queued item %s not found", tostring(id))
	end

	local function remove_at(pane: number, position: number): Item
		local list = queues[pane] :: { Item }
		local item = table.remove(list, position) :: Item
		if #list == 0 then
			queues[pane] = nil
		end
		return item
	end

	local function panes(): { number }
		local sorted: { number } = {}
		for pane in queues do
			table.insert(sorted, pane)
		end
		table.sort(sorted)
		return sorted
	end

	local function enqueue(pane: number, draft: Draft, position: number?): (Item?, string?, number?)
		if not is_integer(pane) then
			return nil, "queue pane must be an integer", nil
		end
		if type(draft) ~= "table" then
			return nil, "queue entry is missing", nil
		end
		if not is_integer(draft.anchor) then
			return nil, "queue anchor must be an integer", nil
		end
		if draft.cid ~= nil and not is_integer(draft.cid) then
			return nil, "queue caller id must be an integer", nil
		end
		local empty = prompt_error(draft.prompt)
		if empty then
			return nil, empty, nil
		end
		local pending = queues[pane]
		local slots = if pending then #pending + 1 else 1
		local slot = position or slots
		if position ~= nil then
			local bad_slot = slot_error(position, slots)
			if bad_slot then
				return nil, bad_slot, nil
			end
		end
		if next_id > MAX_SAFE_INTEGER then
			return nil, "queue ids exhausted", nil
		end
		local enqueued_ms = now()
		local id = next_id
		if reserve_id then
			local reserved, refusal = reserve_id(id)
			if not reserved then
				return nil, refusal or "queue id reservation refused", nil
			end
		end
		local item = make_item(id, pane, draft.anchor, draft.cid, draft.prompt, enqueued_ms)
		next_id = id + 1
		local list = pending
		if list == nil then
			list = {}
			queues[pane] = list
		end
		table.insert(list, slot, item)
		return item, nil, slot
	end

	local function edit(id: number, prompt: string, pane: number?): (Item?, string?, number?)
		local empty = prompt_error(prompt)
		if empty then
			return nil, empty, nil
		end
		local owner, position, item = locate(id, pane)
		if owner == nil or position == nil or item == nil then
			return nil, missing(id, pane), nil
		end
		local replacement = make_item(item.id, item.pane, item.anchor, item.cid, prompt, item.enqueued_ms)
		local list = queues[owner] :: { Item }
		list[position] = replacement
		return replacement, nil, position
	end

	local function cancel_by_id(id: number, pane: number?): (Item?, string?)
		local owner, position, item = locate(id, pane)
		if owner == nil or position == nil or item == nil then
			return nil, missing(id, pane)
		end
		return remove_at(owner, position), nil
	end

	-- The list is handed over because nothing else references it once the pane entry is gone.
	local function clear_pane(pane: number): { Item }
		local list = queues[pane]
		if list == nil then
			return {}
		end
		queues[pane] = nil
		return list
	end

	local function cancel_at(pane: number, position: number?): ({ Item }, string?)
		if position == nil then
			return clear_pane(pane), nil
		end
		local list = queues[pane]
		local bad_slot = slot_error(position, if list then #list else 0)
		if bad_slot then
			return {}, bad_slot
		end
		return { remove_at(pane, position) }, nil
	end

	local function drop_cid(cid: number): { Item }
		local dropped: { Item } = {}
		if type(cid) ~= "number" then
			return dropped
		end
		for _, pane in panes() do
			local list = queues[pane] :: { Item }
			local kept: { Item } = {}
			for _, item in ipairs(list) do
				if item.cid == cid then
					table.insert(dropped, item)
				else
					table.insert(kept, item)
				end
			end
			if #kept == 0 then
				queues[pane] = nil
			elseif #kept < #list then
				queues[pane] = kept
			end
		end
		return dropped
	end

	local function pop_next(pane: number): Item?
		if queues[pane] == nil then
			return nil
		end
		return remove_at(pane, 1)
	end

	-- `to_pos` is the item's final slot in the destination queue; nil appends. A cross-pane move keeps
	-- id, caller, anchor and enqueue time, so the task keeps its identity.
	local function move(id: number, to_pos: number?, to_pane: number?, pane: number?): (Item?, string?, number?)
		local owner, position, item = locate(id, pane)
		if owner == nil or position == nil or item == nil then
			return nil, missing(id, pane), nil
		end
		if to_pos == nil and to_pane == nil then
			return nil, "move needs a target position or pane", nil
		end
		if to_pane ~= nil and not is_integer(to_pane) then
			return nil, "target pane must be an integer", nil
		end
		local destination: number = if to_pane ~= nil then to_pane else owner
		local source = queues[owner] :: { Item }
		local landing = queues[destination]
		local slots = if destination == owner then #source elseif landing then #landing + 1 else 1
		local slot = to_pos or slots
		if to_pos ~= nil then
			local bad_slot = slot_error(to_pos, slots)
			if bad_slot then
				return nil, bad_slot, nil
			end
		end
		if destination == owner then
			if slot ~= position then
				table.remove(source, position)
				table.insert(source, slot, item)
			end
			return item, nil, slot
		end
		remove_at(owner, position)
		local moved = make_item(item.id, destination, item.anchor, item.cid, item.prompt, item.enqueued_ms)
		if landing == nil then
			landing = {}
			queues[destination] = landing
		end
		table.insert(landing, slot, moved)
		return moved, nil, slot
	end

	-- The order must be an exact permutation of the pane's queued ids, so a stale view cannot drop or resurrect tasks.
	local function reorder(pane: number, ordered_ids: { number }): (boolean, string?)
		if type(ordered_ids) ~= "table" then
			return false, "ordered_ids must be a list of item ids"
		end
		-- Reject maps and lists carrying side fields: every key must be one of the list slots checked below.
		local keys = 0
		for _ in pairs(ordered_ids) do
			keys += 1
		end
		if keys ~= #ordered_ids then
			return false, "ordered_ids must be a plain list of item ids"
		end
		local list = queues[pane]
		local size = if list then #list else 0
		if #ordered_ids ~= size then
			return false, string.format("ordered_ids lists %d items but the queue holds %d", #ordered_ids, size)
		end
		if list == nil then
			return true, nil
		end
		local by_id: { [number]: Item } = {}
		for _, item in ipairs(list) do
			by_id[item.id] = item
		end
		local taken: { [number]: boolean } = {}
		local reordered: { Item } = {}
		for slot = 1, size do
			local id = ordered_ids[slot]
			if not is_integer(id) then
				return false, string.format("ordered_ids[%d] must be an item id", slot)
			end
			if taken[id] then
				return false, string.format("ordered_ids lists item %s twice", tostring(id))
			end
			local item = by_id[id]
			if item == nil then
				return false, string.format("queued item %s not found on pane %s", tostring(id), tostring(pane))
			end
			taken[id] = true
			table.insert(reordered, item)
		end
		queues[pane] = reordered
		return true, nil
	end

	local function append_snapshots(out: { Snapshot }, pane: number)
		local list = queues[pane]
		if list then
			for position, item in ipairs(list) do
				table.insert(out, snapshot(item, position))
			end
		end
	end

	return {
		enqueue = enqueue,
		find = locate,
		edit = edit,
		cancel_by_id = cancel_by_id,
		cancel_at = cancel_at,
		clear_pane = clear_pane,
		drop_cid = drop_cid,
		pop_next = pop_next,
		move = move,
		reorder = reorder,
		list = function(pane: number): { Snapshot }
			local out: { Snapshot } = {}
			append_snapshots(out, pane)
			return out
		end,
		-- Snapshots of the given panes, in the order given.
		list_panes = function(selected: { number }): { Snapshot }
			local out: { Snapshot } = {}
			for _, pane in ipairs(selected) do
				append_snapshots(out, pane)
			end
			return out
		end,
		compact = function(pane: number): { Compact }
			local out: { Compact } = {}
			local list = queues[pane]
			if list then
				for position, item in ipairs(list) do
					table.insert(out, { id = item.id, position = position, preview = preview(item.prompt) })
				end
			end
			return out
		end,
		count = function(pane: number): number
			local list = queues[pane]
			return if list then #list else 0
		end,
		panes = panes,
		has_any = function(): boolean
			return next(queues) ~= nil
		end,
	}
end

return { new = new }
