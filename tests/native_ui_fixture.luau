--!nonstrict
--!nolint SameLineStatement
--!nolint ImplicitReturn
-- Fixture for native_ui.luau, run directly (`luau tests/native_ui_fixture.luau` from the repo root): it loads the real
-- module, registers it on a fake host and drives the actual pickers, prompts, Files button and status formatter.
local NativeUi = require("../native_ui")

local function expect(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

-- Pure helpers ------------------------------------------------------------------------------------------------------
expect(NativeUi.short_cwd("/Users/me/project/app"), "…/project/app", "short cwd")
expect(NativeUi.short_cwd("/a/b/"), "/a/b", "short cwd keeps two parts")
expect(NativeUi.short_cwd(""), nil, "short cwd unknown")
expect(NativeUi.files_prefill("/r", { "/r/src/a.lua", "/other/b c" }), 'src/a.lua "/other/b c" ', "files relative+outside")
expect(NativeUi.files_prefill("/r/", {}), "/r/ ", "files root fallback")
expect(NativeUi.files_prefill("/", { "/a", "/b" }), "a b ", "filesystem root")
expect(NativeUi.files_prefill("C:\\Repo", { "c:/repo/a", "c:/repo2/b" }), "a c:/repo2/b ", "Windows path boundary")
expect(NativeUi.files_prefill(nil, {}), nil, "files nothing")
expect(NativeUi.status_segments(nil, "x", 1, 1, "s", "q"), nil, "status unknown")
expect(NativeUi.status_segments("working", nil, 0, 0, "s", "q"), nil, "status quiet")
local segs = NativeUi.status_segments("waiting_input", "boom", 2, 3, "s", "q")
expect(#segs, 3, "status fault+Q+callback")
expect(segs[1].text, "fault", "fault wins over waiting")
expect(segs[2].command, "q", "Q command")
expect(segs[1].icon, "alert-triangle", "fault icon")
expect(segs[2].tone, "warn", "queue tone")
expect(segs[3].text, "↩3", "callback text")
expect(segs[3].command, "s", "callback opens Live Panel")
expect(assert(NativeUi.status_segments("waiting_input", nil, 0, 0, "s", "q"))[1].text, "waiting", "waiting")

local rows = {
	{ pane = 5, title = "solo", state = "idle", queued = 0, current = false },
	{ pane = 3, title = "worker", state = "working", queued = 2, fault = "x", place = "pip", model = "m", cwd = "/a/b/c", owner = 1, current = true },
	{ pane = 1, title = "owner", state = "idle", queued = 0, current = false },
}
local items = NativeUi.switch_items(rows)
expect(items[1].pane, 3, "current tab first")
expect(items[3].group, "Other tabs", "background group")
expect(items[1].group, "Current tab", "current group")
expect(items[1].detail, "working · Q2 · fault · pip · m · …/b/c", "detail")
expect(items[1].current, true, "current")
expect(#NativeUi.action_items(8, 1, false), 3, "no moves available")
expect(NativeUi.choose_target(rows, 3, function() return 9 end), 3, "focused")
expect(NativeUi.choose_target(rows, nil, function() return 9 end), nil, "ambiguous")

-- Fake host ---------------------------------------------------------------------------------------------------------
local commands, button, status_fn = {}, nil, nil
local host = {
	command = function(def) commands[def.id] = def end,
	files = { button = function(def) button = def end },
	chrome = { status = function(fn) status_fn = fn end },
}

local queue = { [10] = { id = 7, pane = 10, position = 1, preview = "do x" }, [11] = { id = 8, pane = 11, position = 1, preview = "do y" } }
local calls, toasts = {}, {}
local bridge = {
	owners = function() return { [11] = 10 } end,
	queued_dispatches = function(p) return if p == 10 then 1 else 0 end,
	queued_callbacks = function() return 0 end,
	fault = function() return nil end,
	unqueue = function() return 0 end,
	queue_prompt = function(id) for _, q in queue do if q.id == id then return q.preview end end return nil end,
	enqueue_prompt = function(_, pane, text) table.insert(calls, "enqueue " .. pane .. " " .. text) return true, nil, true, 9, 2 end,
	edit_queued = function(id, text) table.insert(calls, "edit " .. id .. " " .. text) return true end,
	promote_queued = function(id) table.insert(calls, "top " .. id) return true end,
	cancel_queued_id = function(id) table.insert(calls, "cancel " .. id) return true end,
	all_queued = function() return { queue[11], queue[10] } end,
	move_queued = function(_, id, to) table.insert(calls, "move " .. id .. " " .. to) return true, nil, true end,
}

-- Fake cx: pick/prompt answer at once from a script and hand `next` a fresh cx.
local answers = {}
local picks = {}
local parked = { [11] = true }
local cx
local function awaitable(value)
	return { next = function(_, fn) fn(value, nil, cx) end }
end
cx = {
	session = {
		focused = function() return nil end,
		tab_of = function(p) return 1 end,
		pane = function(_, p) return { title = "t" .. p, parked = parked[p] == true, floating = false, tab = 1 } end,
	},
	agents = { list = function() return { { pane = 10, state = "idle", cwd = "/p/q", model = "m" }, { pane = 11, state = "working", cwd = "/p/r" } } end },
	layout = {
		unpark = function(_, p) parked[p] = nil table.insert(calls, "unpark " .. p) return true end,
		focus = function(_, p) table.insert(calls, "focus " .. p) end,
	},
	pick = function(_, opts) table.insert(picks, opts) local a = table.remove(answers, 1) return awaitable(a(opts.items)) end,
	prompt = function(_, opts) table.insert(picks, opts) return awaitable(table.remove(answers, 1)) end,
	toast = function(_, level, text) table.insert(toasts, text) end,
}
-- Methods are called with `:`, so fake them with a self parameter.
cx.session.focused = function(_) return nil end
cx.session.tab_of = function(_, p) return 1 end
cx.agents.list = function(_) return { { pane = 10, state = "idle", cwd = "/p/q", model = "m" }, { pane = 11, state = "working", cwd = "/p/r" } } end

local states = { [10] = "idle", [11] = "working" }
local ui = NativeUi.new({
	host = host, plugin_id = "wingman", bridge = bridge, states = states, titles = {},
	live_count = function() return 2 end, shutting_down = function() return false end,
	changed = function() end, log = function() end,
})
ui.register()
expect(commands.switch_agent.title, "Wingman: Switch / Search Agents", "switch title")
expect(commands.manage_queue.title, "Wingman: Search / Manage Queue", "manage title")
expect(button.id, "send_to_agent", "Files button id")
expect(commands.switch_agent.available(cx), true, "switch available")
expect(commands.manage_queue.available(cx), true, "manage available")
expect(status_fn({ pane = 10 })[1].text, "Q1", "status Q for pane 10")
expect(status_fn({ pane = 99 }), nil, "status unknown pane")
expect(status_fn({ pane = 10 }), status_fn({ pane = 10 }), "unchanged segments are cached")

-- Switch: pick parked pane 11 -> unpark then focus.
answers = { function(items) for _, i in items do if i.pane == 11 then return i end end end }
commands.switch_agent.run(cx)
expect(table.concat(calls, ","), "unpark 11,focus 11", "unpark then focus")
expect(#picks[1].items, 2, "all live agents listed")

-- Manage: pick #8, then Move, then destination 10 -> dispatched toast.
calls, picks, toasts = {}, {}, {}
answers = {
	function(items) expect(items[1].id, 7, "queue items ordered by pane") return items[2] end,
	function(items) for _, i in items do if i.act == "move" then return i end end error("move action unavailable") end,
	function(items) for _, i in items do if i.pane == 10 then return i end end end,
}
commands.manage_queue.run(cx)
expect(calls[1], "move 8 10", "move called")
expect(toasts[#toasts], "Wingman: prompt #8 sent immediately", "dispatch toast")

-- Files button: selection prefills the prompt; two agents and no focus -> target picker, then the prompt.
calls, picks, toasts = {}, {}, {}
answers = {
	function(items) return items[1] end,
	"src/a.lua fix it",
}
button.run({ root = "/r", selection = { "/r/src/a.lua" }, host = "", tab = "files" }, cx)
expect(picks[2].value, "src/a.lua ", "prefilled prompt")
expect(calls[1], "enqueue 10 src/a.lua fix it", "enqueued from files")

print("native_ui fixture ok")
