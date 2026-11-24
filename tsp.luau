--!strict

local function strip_turn_footer(text: string): string
	-- Trim Tern/omp UI footer chrome like "\n·\n6m44s · 445 tok · $0.06 this turn" or "\n19s · 202K tok this turn"
	local cleaned = string.gsub(text, "\n·\n[^\n]* this turn%s*$", "")
	cleaned = string.gsub(cleaned, "\n[^\n]* this turn%s*$", "")
	return cleaned
end

local function svg_placeholder(svg: string): string
	local label = string.match(svg, 'aria%-label="([^"]*)"')
	if label ~= nil and label ~= "" then
		return "[chart: " .. label .. "]"
	end
	return "[svg chart omitted]"
end

-- Message prose as an agent should read it: SVG charts collapse to one line, usage footer chrome is dropped.
local function clean_message_text(text: string): string
	local cleaned = string.gsub(text, "```[sS][vV][gG].-```", svg_placeholder)
	cleaned = string.gsub(cleaned, "<svg.-</svg>", svg_placeholder)
	return strip_turn_footer(cleaned)
end

-- Length in UTF-16 code units, the unit of TSP `edit` offsets: 4-byte UTF-8 scalars are surrogate pairs.
local function utf16_len(s: string): number
	local units = 0
	for i = 1, #s do
		local b = string.byte(s, i)
		if b < 0x80 or b >= 0xC0 then
			units += if b >= 0xF0 then 2 else 1
		end
	end
	return units
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
	["omp.overlay.approval"] = true,
	["omp.overlay.hook-input"] = true,
	["omp.overlay.hook-select"] = true,
}

local SURFACE_MAX_DEPTH = 64

local function walk_nodes(node: any, depth: number, visit: (any) -> boolean): boolean
	if type(node) ~= "table" or depth > SURFACE_MAX_DEPTH then
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
	if type(node) ~= "table" or depth > SURFACE_MAX_DEPTH or #out >= 400 then
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

local REGION_NAMES = { layer = true, main = true, dock = true }
local TAIL_HYDRATE_COUNT = 8

local function node_matches(n: any, id: string): boolean
	return type(n) == "table" and n.id ~= nil and tostring(n.id) == id
end

local function surface_table(cx: WindowCx, pane_id: number, opts: any): any
	local ok, r = pcall(function()
		return cx.session:surface(pane_id, opts)
	end)
	if ok and type(r) == "table" then
		return r
	end
	return nil
end

-- Native rooted reads return a node; some callers provide a wrapped surface tree.
local function read_root_node(cx: WindowCx, pane_id: number, id: string, opts: { depth: number?, nodes: number? }): any
	local r = surface_table(cx, pane_id, { as = "table", root = id, depth = opts.depth, nodes = opts.nodes })
	if r == nil then
		return nil
	end
	if node_matches(r, id) then
		return r
	end
	if REGION_NAMES[id] and type(r[id]) == "table" then
		return r[id]
	end
	local hit: any = nil
	local function visit(n: any): boolean
		if node_matches(n, id) then
			hit = n
			return true
		end
		return false
	end
	for _, key in ipairs({ "layer", "main", "dock" }) do
		if walk_nodes(r[key], 0, visit) then
			return hit
		end
	end
	return nil
end

local function expand_child(cx: WindowCx, pane_id: number, child: any): any
	if type(child) == "table" and child.id ~= nil then
		return read_root_node(cx, pane_id, tostring(child.id), { nodes = 1500 }) or child
	end
	return child
end

-- Scoped native reads; one full-surface fallback only when every region read failed.
local function read_regions(cx: WindowCx, pane_id: number): any
	local layer = read_root_node(cx, pane_id, "layer", { nodes = 1500 })
	local main = read_root_node(cx, pane_id, "main", { depth = 2, nodes = 5000 })
	local dock = read_root_node(cx, pane_id, "dock", { nodes = 1500 })
	if layer == nil and main == nil and dock == nil then
		local full = surface_table(cx, pane_id, { as = "table", nodes = 5000 })
		if full == nil then
			return nil
		end
		layer, main, dock = full.layer, full.main, full.dock
	end
	return { layer = layer, main = main, dock = dock }
end

local function has_children(n: any): boolean
	return type(n) == "table" and type(n.c) == "table" and #n.c > 0
end

local function find_interactive(node: any): (any, boolean)
	local hit: any = nil
	local truncated = false
	walk_nodes(node, 0, function(n: any): boolean
		truncated = truncated or n.more ~= nil
		local p = n.p
		if type(p) == "table" and INTERACTIVE_ROLES[p.role] and n.id ~= nil then
			hit = n
			return true
		end
		return false
	end)
	return hit, truncated
end

local function find_interactive_in_main(cx: WindowCx, pane_id: number, main: any): any
	local c = if type(main) == "table" then main.c else nil
	if type(c) ~= "table" then
		return nil
	end
	for i = #c, 1, -1 do
		local child = c[i]
		local hit, truncated = find_interactive(child)
		if hit == nil and truncated and i > #c - TAIL_HYDRATE_COUNT then
			hit = find_interactive(expand_child(cx, pane_id, child))
		end
		if hit ~= nil then
			return hit
		end
	end
	return nil
end

local function resolve_interactive_surface(cx: WindowCx, pane_id: number): (any, string?, string?)
	local regions = read_regions(cx, pane_id)
	if regions == nil then
		return nil, nil, nil
	end
	local found = find_interactive(regions.layer)
		or find_interactive_in_main(cx, pane_id, regions.main)
		or find_interactive(regions.dock)
	if found ~= nil then
		local id = tostring(found.id)
		return read_root_node(cx, pane_id, id, { nodes = 2000 }) or found, id, found.p.role
	end
	local layer = regions.layer
	if has_children(layer) then
		local role = if type(layer.p) == "table" and type(layer.p.role) == "string" then layer.p.role else "layer"
		local id = if layer.id ~= nil then tostring(layer.id) else "layer"
		return layer, id, role
	end
	return nil, nil, nil
end

type CardOption = { label: string, detail: string?, selected: boolean, id: string? }
type CardQuestion = {
	number: number,
	field: number,
	prompt: string,
	options: { CardOption },
	option_count: number?,
	other: boolean,
	folded: boolean,
	multi: boolean,
	list_id: string?,
	input_id: string?,
	fold_text: string?,
}
type CardActions = { submit: string?, cancel: string?, approve: string?, deny: string? }
type InteractiveCard = {
	kind: string,
	root_id: string,
	role: string,
	intro: { string },
	title: string,
	details: { string },
	questions: { CardQuestion },
	actions: CardActions,
	input_id: string?,
	text: string,
}

local APPROVAL_ROLES = { ["omp.editor.ask.approval"] = true, ["omp.overlay.approval"] = true }
local ASSISTANT_EXCERPT_BYTES = 400
local APPROVAL_DETAIL_LINES = 12
local APPROVAL_DETAIL_BYTES = 300

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function props(n: any): any
	if type(n) == "table" and type(n.p) == "table" then
		return n.p
	end
	return {}
end

local function kind_of(n: any): string
	return if type(n) == "table" and type(n.k) == "string" then n.k else ""
end

local function id_of(n: any): string?
	return if type(n) == "table" and n.id ~= nil then tostring(n.id) else nil
end

-- Last path component of a node id: `40.body/g0/q0/f0/o1` -> `o1`, `40.actions/submit` -> `submit`.
local function seg_of(n: any): string
	local id = id_of(n)
	if id == nil then
		return ""
	end
	return string.match(id, "[^/%.]+$") or id
end

local function click_of(n: any): string?
	local actions = props(n).actions
	if type(actions) == "table" and type(actions.click) == "string" then
		return actions.click
	end
	return nil
end

local function is_button(n: any): boolean
	return kind_of(n) == "button" or click_of(n) ~= nil
end

local function first_text(p: any, fields: { string }): string
	for _, field in ipairs(fields) do
		local s = trim(spans_to_text(p[field]))
		if s ~= "" then
			return s
		end
	end
	return ""
end

local function find_first(node: any, pred: (any) -> boolean): any
	local hit: any = nil
	walk_nodes(node, 0, function(n: any): boolean
		if pred(n) then
			hit = n
			return true
		end
		return false
	end)
	return hit
end

local function click_in(n: any, clicks: { string }): boolean
	local click = click_of(n)
	return click ~= nil and table.find(clicks, click) ~= nil
end

-- Button whose click action is one of `clicks`; native cards also name them `<root>.actions/<click>`.
local function find_action_node(node: any, clicks: { string }): any
	return find_first(node, function(n: any): boolean
		return click_in(n, clicks)
	end) or find_first(node, function(n: any): boolean
		local id = id_of(n)
		return id ~= nil and string.find(id, ".actions/", 1, true) ~= nil and table.find(clicks, seg_of(n)) ~= nil
	end)
end

-- Topmost question groups (`g0`, `g1`, ...) below `root`.
local function find_groups(node: any, root: any, depth: number, out: { any })
	if type(node) ~= "table" or depth > SURFACE_MAX_DEPTH then
		return
	end
	if node ~= root and string.match(seg_of(node), "^g%d+$") ~= nil then
		table.insert(out, node)
		return
	end
	for _, child in ipairs(if type(node.c) == "table" then node.c else {}) do
		find_groups(child, root, depth + 1, out)
	end
end

local function find_group(node: any, field: number): any
	local groups: { any } = {}
	find_groups(node, node, 0, groups)
	for _, g in ipairs(groups) do
		if seg_of(g) == "g" .. field then
			return g
		end
	end
	return nil
end

local function is_list(n: any): boolean
	return kind_of(n) == "list" or string.match(seg_of(n), "^f%d+$") ~= nil
end

-- The option list of question `field`: the `.../f<field>` node, else the question group's list, else the card's only list.
local function find_question_list(node: any, field: number): any
	local by_id = find_first(node, function(n: any): boolean
		return seg_of(n) == "f" .. field and is_list(n)
	end)
	if by_id ~= nil then
		return by_id
	end
	local group = find_group(node, field)
	if group ~= nil then
		return find_first(group, is_list)
	end
	local lists: { any } = {}
	walk_nodes(node, 0, function(n: any): boolean
		if kind_of(n) == "list" then
			table.insert(lists, n)
		end
		return false
	end)
	return if #lists == 1 then lists[1] else nil
end

local function is_text_input(n: any): boolean
	local kind = kind_of(n)
	return kind == "input" or kind == "editor"
end

local function find_input_node(node: any, field: number?): any
	local scope = node
	if field ~= nil then
		scope = find_group(node, field) or node
	end
	return find_first(scope, is_text_input)
end

-- Human text below `node`. Buttons and lists are chrome unless `chrome` (an option row read for its label).
local function collect_text_lines(node: any, out: { string }, skip: { [any]: boolean }?, chrome: boolean, depth: number)
	if type(node) ~= "table" or depth > SURFACE_MAX_DEPTH or #out >= 80 or (skip ~= nil and skip[node]) then
		return
	end
	local kind = kind_of(node)
	if kind == "spacer" or (not chrome and (kind == "list" or is_button(node))) then
		return
	end
	local own = first_text(props(node), if chrome then { "text", "spans", "label", "title" } else { "text", "spans" })
	if own ~= "" then
		table.insert(out, own)
	end
	for _, child in ipairs(if type(node.c) == "table" then node.c else {}) do
		collect_text_lines(child, out, skip, chrome, depth + 1)
	end
end

local function text_lines(node: any, skip: { [any]: boolean }?): { string }
	local out: { string } = {}
	collect_text_lines(node, out, skip, false, 0)
	return out
end

local function is_selected(n: any, picked: { [string]: boolean }): boolean
	local p = props(n)
	local key = if type(p.key) == "string" then p.key else seg_of(n)
	return p.on == true or p.checked == true or p.selected == true or p.icon == "check" or p.tone == "accent" or picked[key] == true
end

local function selected_keys(p: any): { [string]: boolean }
	local keys: { [string]: boolean } = {}
	for _, field in ipairs({ "selected", "value" }) do
		local v = p[field]
		if type(v) == "string" then
			keys[v] = true
		elseif type(v) == "table" then
			for _, item in ipairs(v) do
				if type(item) == "string" then
					keys[item] = true
				end
			end
		end
	end
	return keys
end

local function option_of(n: any, picked: { [string]: boolean }): CardOption?
	local p = props(n)
	local label = first_text(p, { "label", "text", "spans", "title" })
	local detail = first_text(p, { "detail", "description", "desc", "hint" })
	if label == "" then
		local lines: { string } = {}
		collect_text_lines(n, lines, nil, true, 0)
		label = lines[1] or ""
		if detail == "" then
			detail = lines[2] or ""
		end
	end
	if label == "" then
		return nil
	end
	return {
		label = label,
		detail = if detail ~= "" then detail else nil,
		selected = is_selected(n, picked),
		id = id_of(n),
	}
end

local function is_other_item(n: any): boolean
	return seg_of(n) == "other" or props(n).key == "other"
end

local function is_option_item(n: any): boolean
	return string.match(seg_of(n), "^o%d+$") ~= nil or is_other_item(n)
end

-- Topmost option rows below `container`: native `o<N>` / `other` rows, else any direct child.
local function option_rows(container: any): { any }
	local rows: { any } = {}
	local function gather(n: any, depth: number)
		if type(n) ~= "table" or depth > SURFACE_MAX_DEPTH then
			return
		end
		if n ~= container and is_option_item(n) then
			table.insert(rows, n)
			return
		end
		for _, child in ipairs(if type(n.c) == "table" then n.c else {}) do
			gather(child, depth + 1)
		end
	end
	gather(container, 0)
	if #rows == 0 and kind_of(container) == "list" and type(container.c) == "table" then
		for _, child in ipairs(container.c) do
			if type(child) == "table" and kind_of(child) ~= "spacer" then
				table.insert(rows, child)
			end
		end
	end
	return rows
end

local PICK_CLICKS = { "pick", "select", "choose" }

local function question_prompt(group: any, skip: { [any]: boolean }): string
	local declared = first_text(props(group), { "prompt", "question" })
	if declared ~= "" then
		return declared
	end
	-- Native groups carry the prompt as their `l1` line.
	local line = find_first(group, function(n: any): boolean
		return n ~= group and seg_of(n) == "l1" and kind_of(n) ~= "list"
	end)
	if line ~= nil then
		local lines = text_lines(line, skip)
		if #lines > 0 then
			return table.concat(lines, " ")
		end
	end
	return table.concat(text_lines(group, skip), " ")
end

local function parse_question(group: any, number: number, default_field: number): CardQuestion
	local list = find_first(group, is_list)
	local fold = find_first(group, function(n: any): boolean
		return props(n).role == "omp.ask.fold"
	end)
	local container = list or fold
	local skip: { [any]: boolean } = {}
	if container ~= nil then
		skip[container] = true
	end
	if fold ~= nil then
		skip[fold] = true
	end
	local prompt = question_prompt(group, skip)

	local options: { CardOption } = {}
	local other = false
	local unmounted = false
	local multi = false
	if container ~= nil then
		local cp = props(container)
		local picked = selected_keys(cp)
		multi = cp.multi == true or cp.multiple == true or cp.mode == "multi" or cp.mode == "multiple"
		unmounted = container.more ~= nil
		for _, row in ipairs(option_rows(container)) do
			if row.more ~= nil then
				unmounted = true
			end
			if is_other_item(row) then
				other = true
			else
				local option = option_of(row, picked)
				if option ~= nil then
					table.insert(options, option)
					multi = multi or props(row).checked ~= nil
				end
			end
		end
	else
		walk_nodes(group, 0, function(n: any): boolean
			if click_in(n, PICK_CLICKS) then
				local option = option_of(n, {})
				if option ~= nil then
					table.insert(options, option)
				end
			end
			return false
		end)
	end

	local fold_text: string? = nil
	if fold ~= nil and #options == 0 then
		local lines = text_lines(fold, nil)
		if prompt == "" and #lines > 0 then
			prompt = table.remove(lines, 1) or ""
		end
		local rest: { string } = {}
		for _, line in ipairs(lines) do
			if line ~= prompt then
				table.insert(rest, line)
			end
		end
		if #rest > 0 then
			fold_text = table.concat(rest, " ")
		end
	end
	local field = default_field
	if list ~= nil then
		local n = string.match(seg_of(list), "^f(%d+)$")
		if n ~= nil then
			field = tonumber(n) or default_field
		end
	end
	return {
		number = number,
		field = field,
		prompt = prompt,
		options = options,
		option_count = if #options > 0 and not unmounted then #options else nil,
		other = other or (fold ~= nil and #options == 0),
		folded = fold ~= nil,
		multi = multi,
		list_id = id_of(list),
		input_id = id_of(find_first(group, is_text_input)),
		fold_text = fold_text,
	}
end

local function parse_intro(node: any, skip: { [any]: boolean }): { string }
	local intro: { string } = {}
	local function gather(n: any, depth: number)
		if type(n) ~= "table" or depth > SURFACE_MAX_DEPTH or skip[n] then
			return
		end
		local id = id_of(n)
		if seg_of(n) == "intro" or (id ~= nil and string.find(id, "/intro/", 1, true) ~= nil) then
			for _, line in ipairs(text_lines(n, skip)) do
				table.insert(intro, line)
			end
			return
		end
		for _, child in ipairs(if type(n.c) == "table" then n.c else {}) do
			gather(child, depth + 1)
		end
	end
	gather(node, 0)
	return intro
end

-- Compact text of an overlay nobody modelled: only nodes that say something or can be acted on.
local function compact_lines(node: any, out: { string }, depth: number)
	if type(node) ~= "table" or depth > SURFACE_MAX_DEPTH or #out >= 40 or kind_of(node) == "spacer" then
		return
	end
	local p = props(node)
	if is_button(node) then
		local label = first_text(p, { "label", "text", "spans", "title" })
		if label ~= "" then
			table.insert(out, "[" .. label .. "]")
		end
		return
	end
	if kind_of(node) == "list" then
		local picked = selected_keys(p)
		for _, row in ipairs(option_rows(node)) do
			local option = option_of(row, picked)
			if option ~= nil then
				table.insert(out, "- " .. option.label .. (if option.selected then " (selected)" else ""))
			end
		end
		return
	end
	local own = first_text(p, { "text", "spans", "label", "title" })
	if own ~= "" then
		table.insert(out, own)
	end
	for _, child in ipairs(if type(node.c) == "table" then node.c else {}) do
		compact_lines(child, out, depth + 1)
	end
end

-- Overlay footers like "enter approve · esc deny" are key legends, not decision content.
local function looks_like_key_hint(line: string): boolean
	return string.find(line, "·", 1, true) ~= nil and (string.find(line, "approve", 1, true) ~= nil or string.find(line, "deny", 1, true) ~= nil)
end

local function parse_approval(node: any, card: InteractiveCard)
	local title_node = find_first(node, function(n: any): boolean
		return props(n).role == "omp.approval.title" or seg_of(n) == "title"
	end)
	local details_node = find_first(node, function(n: any): boolean
		return props(n).role == "omp.approval.details" or seg_of(n) == "details"
	end)
	local title = if title_node ~= nil then table.concat(text_lines(title_node, nil), " ") else ""
	local skip: { [any]: boolean } = {}
	if title_node ~= nil then
		skip[title_node] = true
	end
	local lines = text_lines(details_node or node, skip)
	if title == "" then
		title = first_text(props(node), { "title", "text", "spans" })
		if title == "" and details_node == nil then
			title = table.remove(lines, 1) or ""
		end
	end
	for _, line in ipairs(lines) do
		if line ~= title and not looks_like_key_hint(line) then
			table.insert(card.details, line)
		end
	end
	card.title = title
end

local function parse_interactive_card(node: any, root_id: string?, role: string?): InteractiveCard
	local role_name = role or ""
	local card: InteractiveCard = {
		kind = "unknown",
		root_id = root_id or "",
		role = role_name,
		intro = {},
		title = "",
		details = {},
		questions = {},
		actions = {},
		input_id = nil,
		text = "",
	}
	if type(node) ~= "table" then
		return card
	end
	local function action_id(clicks: { string }): string?
		return id_of(find_action_node(node, clicks))
	end
	card.actions = {
		submit = action_id({ "submit" }),
		cancel = action_id({ "cancel" }),
		approve = action_id({ "approve", "grant" }),
		deny = action_id({ "deny" }),
	}
	if role_name == "omp.ask.card" then
		local groups: { any } = {}
		find_groups(node, node, 0, groups)
		local skip: { [any]: boolean } = {}
		for _, g in ipairs(groups) do
			skip[g] = true
		end
		card.intro = parse_intro(node, skip)
		if #groups == 0 then
			table.insert(card.questions, parse_question(node, 1, 0))
		else
			for i, g in ipairs(groups) do
				local field = tonumber(string.match(seg_of(g), "^g(%d+)$")) or (i - 1)
				table.insert(card.questions, parse_question(g, i, field))
			end
		end
		card.kind = "ask"
	elseif role_name == "omp.overlay.hook-select" then
		table.insert(card.questions, parse_question(node, 1, 0))
		card.kind = "select"
	elseif role_name == "omp.overlay.hook-input" then
		card.title = table.concat(text_lines(node, nil), " ")
		card.input_id = id_of(find_first(node, is_text_input))
		card.kind = "input"
	elseif APPROVAL_ROLES[role_name] then
		parse_approval(node, card)
		card.kind = "approval"
	end
	local first = card.questions[1]
	local meaningful = if card.kind == "ask" or card.kind == "select"
		then first ~= nil and (first.prompt ~= "" or #first.options > 0 or first.folded)
		elseif card.kind == "input" or card.kind == "approval" then card.title ~= "" or #card.details > 0
		else false
	if not meaningful then
		card.kind = "unknown"
		local lines: { string } = {}
		compact_lines(node, lines, 0)
		card.text = table.concat(lines, "\n")
	end
	return card
end

local function format_question(q: CardQuestion, label: string, out: { string }, multi_question: boolean)
	table.insert(out, label .. ": " .. q.prompt .. (if q.multi then " [multi-select]" else ""))
	for i, option in ipairs(q.options) do
		table.insert(out, string.format(
			"  %d. %s%s%s",
			i,
			option.label,
			if option.detail ~= nil then " — " .. option.detail else "",
			if option.selected then " (selected)" else ""
		))
	end
	if #q.options == 0 and q.folded then
		table.insert(out, "  (options collapsed; answer by number" .. (if q.fold_text ~= nil then "; " .. q.fold_text else "") .. ")")
	end
	if q.other then
		table.insert(out, if multi_question
			then string.format('  (or --question %d --other "<text>")', q.number)
			else '  (or --other "<text>")')
	end
end

local function format_card_summary(card: InteractiveCard, pane_id: number): string
	local out: { string } = {}
	local reply: string
	if card.kind == "ask" then
		for _, line in ipairs(card.intro) do
			table.insert(out, line)
		end
		local multi_question = #card.questions > 1
		local any_other = false
		for _, q in ipairs(card.questions) do
			format_question(q, if multi_question then "Q" .. q.number else "Q", out, multi_question)
			any_other = any_other or q.other
		end
		local choices: { string } = {}
		for i = 1, #card.questions do
			table.insert(choices, if multi_question then string.format("<q%d_choice>", i) else "<choice>")
		end
		reply = string.format("Reply: `wingman answer --pane %d %s`", pane_id, table.concat(choices, " "))
		if any_other then
			reply ..= if multi_question then ' | `--question <N> --other "<text>"`' else ' | `--other "<text>"`'
		end
		reply ..= " | `--cancel`"
	elseif card.kind == "approval" then
		table.insert(out, "Approval needed" .. (if card.title ~= "" then ": " .. card.title else ""))
		for i, line in ipairs(card.details) do
			if i > APPROVAL_DETAIL_LINES then
				table.insert(out, string.format("  … (%d more lines)", #card.details - APPROVAL_DETAIL_LINES))
				break
			end
			table.insert(out, "  " .. clip_utf8_bytes(line, APPROVAL_DETAIL_BYTES))
		end
		reply = string.format("Reply: `wingman answer --pane %d --approve` | `--deny`", pane_id)
	elseif card.kind == "input" then
		table.insert(out, "Input requested: " .. card.title)
		reply = string.format('Reply: `wingman answer --pane %d --other "<text>"` | `--cancel`', pane_id)
	else
		if card.text ~= "" then
			table.insert(out, card.text)
		end
		reply = string.format("Inspect: `wingman surface --pane %d`", pane_id)
	end
	table.insert(out, reply)
	return table.concat(out, "\n")
end

local function build_waiting_summary(cx: WindowCx, pane_id: number): (string, string)
	local node, root_id, role = resolve_interactive_surface(cx, pane_id)
	local key = tostring(role or "waiting") .. ":" .. tostring(root_id or "root")
	if node ~= nil then
		return key, format_card_summary(parse_interactive_card(node, root_id, role), pane_id)
	end
	local parts: { string } = {
		string.format("Waiting for input; no interactive card is mounted. Inspect: `wingman surface --pane %d`", pane_id),
	}
	local ok_tr, msgs = pcall(function()
		return cx.agents:transcript(pane_id, { last = 2 })
	end)
	if ok_tr and type(msgs) == "table" then
		for i = #msgs, 1, -1 do
			local m = msgs[i]
			if m.role == "assistant" then
				local excerpt = if type(m.text) == "string" then trim(clip_utf8_bytes(clean_message_text(m.text), ASSISTANT_EXCERPT_BYTES)) else ""
				if excerpt ~= "" then
					table.insert(parts, "Last assistant message:\n" .. excerpt)
				end
				break
			end
		end
	end
	return key, table.concat(parts, "\n\n")
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
	local dock = read_root_node(cx, pane_id, "dock", { nodes = 1500 })
	local main = read_root_node(cx, pane_id, "main", { depth = 2, nodes = 5000 })
	if dock == nil and main == nil then
		local full = surface_table(cx, pane_id, { as = "table", nodes = 5000 })
		if full == nil then
			return false, nil, nil
		end
		dock, main = full.dock, full.main
	end
	local has_retry_hint = false
	local banner_text: string? = nil
	local abort_text: string? = nil
	local error_text: string? = nil
	local has_retry_error = false
	walk_nodes(dock, 0, function(n: any): boolean
		local role = type(n.p) == "table" and n.p.role or nil
		if role == "omp.hint.retry" then
			has_retry_hint = true
		elseif role == "omp.errorBanner" then
			banner_text = node_text(n)
		end
		return false
	end)
	local main_c = if type(main) == "table" then main.c else nil
	local tail = if type(main_c) == "table" then expand_child(cx, pane_id, main_c[#main_c]) else nil
	walk_nodes(tail, 0, function(n: any): boolean
		local role = type(n.p) == "table" and n.p.role or nil
		if role == "omp.error" then
			has_retry_error = true
			error_text = node_text(n)
			return true
		elseif role == "omp.assistant.abort" then
			abort_text = node_text(n)
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
	local key = "fault:" .. tostring(tail and tail.id or "dock") .. ":" .. clip_utf8_bytes(summary, 120)
	return true, key, summary
end

return {
	spans_to_text = spans_to_text,
	clip_utf8_bytes = clip_utf8_bytes,
	strip_turn_footer = strip_turn_footer,
	clean_message_text = clean_message_text,
	utf16_len = utf16_len,
	parse_interactive_card = parse_interactive_card,
	find_action_node = find_action_node,
	find_question_list = find_question_list,
	find_input_node = find_input_node,
	read_root_node = read_root_node,
	resolve_interactive_surface = resolve_interactive_surface,
	format_tsp_subtree = format_tsp_subtree,
	build_waiting_summary = build_waiting_summary,
	inspect_fault_surface = inspect_fault_surface,
}
