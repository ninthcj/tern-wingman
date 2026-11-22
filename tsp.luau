--!strict

local function strip_turn_footer(text: string): string
	-- Trim Tern/omp UI footer chrome like "\n·\n6m44s · 445 tok · $0.06 this turn" or "\n19s · 202K tok this turn"
	local cleaned = string.gsub(text, "\n·\n[^\n]* this turn%s*$", "")
	cleaned = string.gsub(cleaned, "\n[^\n]* this turn%s*$", "")
	return cleaned
end

local function clip_utf8_bytes(s: string, max_bytes: number): string
	if #s <= max_bytes then
		return s
	end
	local cut = max_bytes
	-- Walk back past any UTF-8 continuation bytes (0x80..0xBF) so we never split a multi-byte character.
	while cut > 0 do
		local b = string.byte(s, cut + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(s, 1, cut)
end

local INTERACTIVE_ROLES = {
	["omp.ask.card"] = true,
	["omp.editor.ask.approval"] = true,
	["omp.overlay.hook-input"] = true,
	["omp.overlay.hook-select"] = true,
}

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
		if target_node == nil and type(tree.layer) == "table" then
			-- Generic fallback for non-omp ACP approval/dialog overlays rendered in the TSP `layer` region.
			target_node = tree.layer
			root_id = if target_node.id ~= nil then tostring(target_node.id) else "layer"
			role = if type(target_node.p) == "table" and type(target_node.p.role) == "string"
				then target_node.p.role
				else "layer"
		end
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
				break
			end
		end
	end
	table.insert(parts, string.format("Interactive surface (%s · root %s):\n%s", tostring(role or "unknown"), tostring(root_id or "-"), surface_text))
	table.insert(parts, string.format(
		"Inspect: `wingman surface --pane %d`. Answer via `wingman event --pane %d '<json-event>' ...` (see `wingman` skill for multi-step/Other recipes). "
			.. "Decide technical/architectural questions yourself; consult the user first on product/scope/cost trade-offs.",
		pane_id, pane_id
	))
	return tostring(role or "waiting") .. ":" .. tostring(root_id or "root"), table.concat(parts, "\n\n")
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

return {
	spans_to_text = spans_to_text,
	clip_utf8_bytes = clip_utf8_bytes,
	strip_turn_footer = strip_turn_footer,
	find_node_by_id = find_node_by_id,
	find_interactive_root = find_interactive_root,
	format_tsp_subtree = format_tsp_subtree,
	build_waiting_summary = build_waiting_summary,
	inspect_fault_surface = inspect_fault_surface,
}
