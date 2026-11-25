--!strict
-- The Python test copies the dependency modules beside the generated script and injects window.luau here,
-- so the real mux handler and real modules run under stock Luau. Only Tern's outer API, the live panel
-- and mux byte transport are replaced.
local handlers: { [string]: (any, any?) -> () } = {}
local effects: { { op: string, target: number, prompt: string? } } = {}
local store: { [string]: any } = {}
local frame: any
local replies: { [number]: any } = {}
local request_id = 1
local disconnected = false
local clock = 0
local watchdog: ((any) -> ())?
local timers: { { ms: number, callback: (any) -> () } } = {}
local request: { [string]: any }
local receive: (string, any) -> ()
local function unexpected(message: any)
    error(tostring(message), 2)
end
local tern = {
    runtime = { os = "macos" },
    plugin = { dir = ".", id = "wingman" },
    getenv = function() return nil end,
    now = function() return clock end,
    timer = function(ms, callback)
        table.insert(timers, { ms = ms, callback = callback })
        if ms == 500 then
            watchdog = callback
        end
    end,
    command = function() end,
    on = function(event, callback) handlers[event] = callback end,
    log = { error = unexpected, warn = unexpected },
    kv = {
        set = function(key, value) store[key] = value end,
        get = function(key) return store[key] end,
    },
    json = {
        array = function(rows) return rows or {} end,
        encode = function(value) frame = value; replies[value.id] = value; return "reply" end,
        decode = function() return { id = request_id, req = request, disconnected = disconnected } end,
    },
    process = {
        spawn = function(_, options)
            receive = options.stdout
            return { write = function() end }
        end,
    },
}
local notifications = 0
local radar_bridge: any
local real_require = require
local function fixture_require(path: string): any
    if path == "./radar" then
        return { on_state_change = function() notifications += 1 end, attach = function(b) radar_bridge = b end }
    end
    return real_require(path)
end
local function load_plugin(require: (string) -> any)
-- @WINDOW_PLUGIN@
end

local function effect(op: string, target: number, prompt: string?)
    table.insert(effects, { op = op, target = target, prompt = prompt })
end
local panes = {}
local agents = {}
for id = 1, 4 do
    panes[id] = { pane = id, tab = 42, cwd = "/work" }
    agents[id] = { pane = id, cwd = "/work", state = "idle" }
end
local tab_tree: TabTree? = nil
local focused_pane = 1
local floated_over: number? = nil
local moved_next_to: number? = nil
local live_panel: number? = nil

-- The surface mock follows Tern's capped reads: `nodes` is a preorder budget, `depth` counts levels below the
-- root, and descendants left out are reported through `more`. Panes without a registered surface mount the
-- default simple one, which carries the `test` node the shared RPC events address.
type SurfaceCall = { pane: number, as: any, root: any, depth: any, nodes: any }
local mock = {
    surfaces = {} :: { [number]: any },
    absent = {} :: { [number]: boolean },
    calls = {} :: { SurfaceCall },
    assistant_text = nil :: string?,
    rooted_reads = true,
    rooted_wrapper = false,
    missing_root_raises = false,
    event_failure = nil :: string?,
    on_event = nil :: ((number, any) -> ())?,
}
local SURFACE_REGIONS = { "main", "dock", "layer" }

local function node(id: string, kind: string, props: { [string]: any }?, children: { any }?): any
    return { id = id, k = kind, p = props, c = children }
end

local function count_nodes(source: any): number
    local total = 1
    for _, child in source.c or {} do
        total += count_nodes(child)
    end
    return total
end

local function locate(tree: any, id: string): (string?, any)
    local function search(source: any): any
        if source.id == id then
            return source
        end
        for _, child in source.c or {} do
            local hit = search(child)
            if hit ~= nil then
                return hit
            end
        end
        return nil
    end
    for _, region in SURFACE_REGIONS do
        local root = tree[region]
        local hit = if root ~= nil then search(root) else nil
        if hit ~= nil then
            return region, hit
        end
    end
    return nil, nil
end

local function clip_node(source: any, depth: number?, budget: { left: number }): any
    budget.left -= 1
    local copy: { [string]: any } = { id = source.id, k = source.k, p = source.p }
    local children: { any }? = source.c
    if children == nil or #children == 0 then
        return copy
    end
    if depth ~= nil and depth <= 0 then
        copy.more = count_nodes(source) - 1
        return copy
    end
    local kept: { any } = {}
    local omitted = 0
    for _, child in children do
        if budget.left > 0 then
            table.insert(kept, clip_node(child, if depth ~= nil then depth - 1 else nil, budget))
        else
            omitted += count_nodes(child)
        end
    end
    if #kept > 0 then
        copy.c = kept
    end
    if omitted > 0 then
        copy.more = omitted
    end
    return copy
end

local function collect_text(source: any, lines: { string })
    local props = source.p
    if props ~= nil then
        for _, field in { "text", "label" } do
            if type(props[field]) == "string" then
                table.insert(lines, props[field])
            end
        end
    end
    for _, child in source.c or {} do
        collect_text(child, lines)
    end
end

local function default_surface(): any
    return {
        surface = { id = "surface-default", mode = "screen" },
        main = node("main", "stack", nil, { node("test", "button", { label = "Submit", actions = { click = "submit" } }) }),
    }
end

local function read_surface(pane: number, opts: any): any
    local read = opts or {}
    table.insert(mock.calls, { pane = pane, as = read.as, root = read.root, depth = read.depth, nodes = read.nodes })
    local tree = if mock.absent[pane] then nil else (mock.surfaces[pane] or default_surface())
    if tree == nil then
        return nil
    end
    if read.root ~= nil and not mock.rooted_reads then
        error("rooted surface reads are unavailable")
    end
    if read.as == "text" then
        local lines: { string } = {}
        for _, region in SURFACE_REGIONS do
            if tree[region] ~= nil then
                collect_text(tree[region], lines)
            end
        end
        return string.sub(table.concat(lines, "\n"), 1, read.max_chars or 8000)
    end
    local budget = { left = read.nodes or 500 }
    if read.root ~= nil then
        local region, hit = locate(tree, read.root)
        if hit == nil then
            if mock.missing_root_raises then
                error("surface node " .. tostring(read.root) .. " not found")
            end
            return nil
        end
        local clipped = clip_node(hit, read.depth, budget)
        return if mock.rooted_wrapper then { surface = tree.surface, [region :: string] = clipped } else clipped
    end
    local out: { [string]: any } = { surface = tree.surface }
    local omitted = 0
    for _, region in SURFACE_REGIONS do
        local root = tree[region]
        if root ~= nil then
            if budget.left > 0 then
                out[region] = clip_node(root, read.depth, budget)
            else
                omitted += count_nodes(root)
            end
        end
    end
    if omitted > 0 then
        out.more = omitted
    end
    return out
end
local custom_agents: { [any]: any } = { { id = "zeta" } :: any, { name = "alpha.1" } :: any, "zeta" :: any, { id = "Bad" } :: any, bare = {}, ["-x"] = {} }
local cx = {
    settings = { get = function(_, key) assert(key == "agents.custom"); return custom_agents end },
    window_key = function() return "" end,
    session = {
        pane = function(_, id) return panes[id] end,
        tab_of = function(_, id) return panes[id].tab end,
        layout = function() return { floats = {}, root = tab_tree, tab = 42 } end,
        focused = function() return focused_pane end,
        surface = function(_, pane, opts) return read_surface(pane, opts) end,
        event = function(_, pane, ev)
            if mock.event_failure then
                error(mock.event_failure)
            end
            effect("event", pane, if ev.id ~= nil then tostring(ev.id) else nil)
            if mock.on_event then
                mock.on_event(pane, ev)
            end
        end,
    },
    canvas = {
        list = function()
            return if live_panel then { { pane = live_panel, title = "Wingman Live", owner = "wingman" } } else {}
        end,
    },
    agents = {
        list = function() return agents end,
        ask = function(_, pane, prompt) effect("ask", pane, prompt) end,
        transcript = function()
            return if mock.assistant_text then { { role = "assistant", text = mock.assistant_text } } else {}
        end,
    },
    layout = {
        float = function(_, pane, over, _, opts)
            floated_over = over
            assert(opts.focus == false)
            effect("pip", pane)
            return true
        end,
        unpark = function(_, pane, opts)
            assert(opts.focus == false)
            effect("unpark", pane)
            return true
        end,
        move = function(_, pane, target, _, opts)
            assert(opts.focus == false)
            moved_next_to = target
            effect("move", pane)
            return true
        end,
        dock = function(_, pane) effect("dock", pane); return true end,
    },
}
local function rpc(op: string, anchor: number, target: number?, extra: { [string]: any }?): any
    frame = nil
    request_id += 1
    request = { op = op, anchor_pane = anchor, target_pane = target, prompt = "hello", async_callback = true,
        events = { { ev = "action", id = "test", act = "submit" } } }
    if extra then
        for key, value in extra do
            request[key] = value
        end
    end
    receive("request", cx)
    assert(frame and frame.reply, op .. " did not reply")
    return frame.reply
end
local function start(data: { [string]: any }?)
    watchdog = nil
    timers = {}
    clock = 0
    store = data or {}
    load_plugin(fixture_require)
    handlers.window_start(cx)
end
local function assert_cycle(op: string, anchor: number, target: number)
    local before = #effects
    local out = rpc(op, anchor, target)
    assert(not out.ok and string.find(out.error or "", "ownership cycle", 1, true), op .. ": " .. tostring(out.error))
    assert(#effects == before, op .. " performed a pane effect before rejecting the cycle")
end

start()
assert(rpc("dispatch", 1, 2).ok)
assert(rpc("dispatch", 2, 3).ok)
assert(rpc("pip", 2, 4).ok)
assert_cycle("dispatch", 2, 1)
for _, op in { "dispatch", "pip", "dock", "retry", "event", "await" } do
    assert_cycle(op, 3, 1)
end
assert(rpc("status", 1).bound_pane == 2)
local middle = rpc("status", 2)
assert(middle.owner_pane == 1 and middle.bound_pane == nil)
assert(#middle.bound_panes == 2 and middle.bound_panes[1] == 3 and middle.bound_panes[2] == 4)
assert(rpc("status", 3).owner_pane == 2 and #rpc("status", 3).bound_panes == 0)

-- A v0.5 store could already contain a cycle. Keep the first two edges and repair the store.
start({ owners_v1 = { ["1"] = 3, ["2"] = 1, ["3"] = 2, ["4"] = 2 } })
assert(store.owners_v1["3"] == nil and store.owners_v1["4"] == 2)
assert_cycle("dispatch", 2, 3)

-- Persisted policy and dedup keys survive a restart; entries for closed panes are pruned at start.
start({
    auto_callback_v1 = { default = false, owners = { ["1"] = true, ["99"] = true } },
    notified_waiting_v1 = { ["1"] = "waiting:a", ["99"] = "waiting:b" },
})
assert(store.notified_waiting_v1["1"] == "waiting:a" and store.notified_waiting_v1["99"] == nil)
assert(store.auto_callback_v1.default == false and store.auto_callback_v1.owners["1"] == true)
assert(store.auto_callback_v1.owners["99"] == nil)
local restored = rpc("status", 1)
assert(restored.auto_callback == true and restored.default_auto_callback == false)
assert(rpc("status", 2).auto_callback == false)

-- Ownership edges persist and notify the panel; the callback op edits policy through the same module.
start()
local before_bind = notifications
assert(rpc("dispatch", 1, 2).ok)
assert(notifications > before_bind and store.owners_v1["2"] == 1)
local off = rpc("callback", 1, nil, { mode = "off", scope = "owner" })
assert(off.enabled == false and off.default_enabled == true and off.owner_pane == 1)
assert(tern.kv.get("auto_callback_v1").owners["1"] == false)
assert(rpc("dispatch", 1, 3).ok)
assert(tern.kv.get("auto_callback_v1").owners["1"] == true, "an async dispatch re-arms a disabled callback")
local global_off = rpc("callback", 1, nil, { mode = "off", scope = "global" })
assert(global_off.default_enabled == false and tern.kv.get("auto_callback_v1").default == false)
local reset = rpc("callback", 1, nil, { mode = "reset", scope = "global" })
assert(reset.default_enabled == true and tern.kv.get("auto_callback_v1").default == true)
assert(next(store.auto_callback_v1.owners) == nil)

-- bind guards the graph at the mutation itself, independent of any caller preflight.
store = {}
local state = real_require("./state").new({ kv = tern.kv, log = tern.log, notify = function() end })
assert(state.bind_wingman(1, 2) == nil and state.bind_wingman(2, 3) == nil)
local saved = store.owners_v1
assert(string.find(state.bind_wingman(3, 1) or "", "ownership cycle", 1, true))
assert(string.find(state.bind_wingman(1, 1) or "", "ownership cycle", 1, true))
assert(state.raw_owner(1) == nil and state.raw_owner(3) == 2 and store.owners_v1 == saved)
assert(state.owners()[2] == 1 and state.bind_wingman(1, 2) == nil)
state.unbind_pane(2)
assert(state.raw_owner(2) == nil and state.raw_owner(3) == nil and store.owners_v1["3"] == nil)

local function queue_rpc(action: string, fields: { [string]: any }?, pane: number?, anchor: number?): any
    local req = table.clone(fields or {})
    req.action = action
    return rpc("queue", anchor or 1, pane, req)
end

start({ auto_callback_v1 = { default = false } })
local direct = rpc("dispatch", 1, 2, { prompt = "first" })
local before_queued = #effects
local second = rpc("dispatch", 1, 2, { prompt = "second", async_callback = false })
local second_cid = request_id
local third = rpc("dispatch", 1, 2, { prompt = "third", position = 1 })
assert(direct.ok and not direct.queued and second._ack and second.queued and second.position == 1)
assert(third.ok and third.queued and third.position == 1 and third.queue_id > second.queue_id)
assert(#effects == before_queued, "rapid sends while native state still says idle must not reach cx.agents:ask")
assert(not rpc("dispatch", 1, 2, { position = 4, layout = "pip" }).ok and #effects == before_queued)

local listed = queue_rpc("list", { all = true }).items
assert(#listed == 2 and listed[1].id == third.queue_id and listed[2].waiting_caller)
local compact = rpc("status", 1).agents[2]
assert(compact.queued_count == 2 and compact.queued_preview == "third" and compact.queued_items[1].id == third.queue_id)
assert(not queue_rpc("edit", { id = third.queue_id, prompt = "stolen" }, nil, 4).ok)
assert(not rpc("unqueue", 4, 2, { position = 1 }).ok)
assert(not queue_rpc("edit", { id = third.queue_id, prompt = "wrong" }, 3).ok)
assert(not queue_rpc("edit", { id = third.queue_id, prompt = " \n" }).ok)
assert(queue_rpc("edit", { id = third.queue_id, prompt = "edited third" }).prompt == "edited third")
assert(not queue_rpc("reorder", { ordered_ids = { second.queue_id, second.queue_id } }, 2).ok)
assert(queue_rpc("reorder", { ordered_ids = { second.queue_id, third.queue_id } }).items[1].id == second.queue_id)
assert(queue_rpc("move", { id = third.queue_id, to_pos = 1 }).position == 1)

agents[3].state = "waiting_input"
local refused = queue_rpc("move", { id = third.queue_id, to_pane = 3 })
assert(not refused.ok and string.find(refused.error, "waiting_input", 1, true) and #effects == before_queued)
agents[3].state = "exited"
assert(not queue_rpc("move", { id = third.queue_id, to_pane = 3 }).ok and #effects == before_queued)
agents[3].state = "idle"
assert(queue_rpc("list", nil, 2).items[1].id == third.queue_id and rpc("status", 3).owner_pane == nil)
assert(not queue_rpc("move", { id = third.queue_id, to_pane = 3, to_pos = 2 }).ok)
local moved = queue_rpc("move", { id = third.queue_id, to_pane = 3 })
assert(moved.ok and moved.dispatched and moved.pane == 3 and moved.id == third.queue_id)
assert(effects[before_queued + 1].target == 3 and effects[before_queued + 1].prompt == "edited third")
assert(rpc("status", 3).owner_pane == 1)
assert(not queue_rpc("edit", { id = third.queue_id, prompt = "stale" }).ok)
assert(not queue_rpc("cancel", { id = third.queue_id }).ok)
assert(queue_rpc("list", nil, 2).items[1].id == second.queue_id)
assert(rpc("unqueue", 1, nil, { id = second.queue_id }).cancelled == 1)
assert(replies[second_cid].reply.status == "cancelled" and not replies[second_cid].keep_open)

local fourth = rpc("dispatch", 1, 2, { prompt = "fourth" })
local fifth = rpc("dispatch", 1, 2, { prompt = "fifth", async_callback = false })
local fifth_cid = request_id
assert(fourth.queued and fifth.queued)
local timer = assert(watchdog)
clock = 500
timer(cx)
assert(#effects == before_queued + 1, "watchdog must not promote during the native handoff")
disconnected = true
request_id = fifth_cid
receive("disconnect", cx)
disconnected = false
assert(queue_rpc("list", nil, 2).items[2] == nil)
agents[2].state = "working"
handlers.agent_state({ pane = 2, old = "idle", new = "working" }, cx)
agents[2].state = "idle"
handlers.agent_finished({ pane = 2, result = "done" }, cx)
assert(effects[#effects].target == 2 and effects[#effects].prompt == "fourth")
assert(not queue_rpc("cancel", { id = fourth.queue_id }).ok)

local sixth = rpc("dispatch", 1, 2, { prompt = "sixth" })
local seventh = rpc("dispatch", 1, 2, { prompt = "seventh" })
assert(queue_rpc("reorder", { ordered_ids = { sixth.queue_id, seventh.queue_id, 2 }, allow_trailing_pane = true }).ok)
assert(queue_rpc("cancel", { position = 1 }, 2).cancelled == 1)
assert(not queue_rpc("edit", { id = sixth.queue_id, prompt = "stale" }).ok)
assert(queue_rpc("list", nil, 2).items[1].id == seventh.queue_id)
assert(queue_rpc("cancel", { all = true }, 2).cancelled == 1)

start(store)
agents[2].state = "working"
local reloaded = rpc("dispatch", 1, 2, { prompt = "after reload" })
assert(reloaded.queue_id > seventh.queue_id and not queue_rpc("cancel", { id = seventh.queue_id }).ok)
assert(queue_rpc("list", nil, 2).items[1].id == reloaded.queue_id)

start({ owners_v1 = { ["2"] = 1, ["4"] = 3 }, auto_callback_v1 = { default = false } })
local pending_move = rpc("dispatch", 1, 2, { prompt = "move and wait", async_callback = false })
local move_cid = request_id
assert(pending_move._ack and pending_move.queued)
assert(not queue_rpc("move", { id = pending_move.queue_id, to_pane = 4 }).ok)
agents[3].state = "working"
local busy_move = queue_rpc("move", { id = pending_move.queue_id, to_pane = 3 })
assert(busy_move.ok and not busy_move.dispatched and busy_move.position == 1)
assert(#queue_rpc("list", nil, 2).items == 0)
assert(queue_rpc("list", nil, 3).items[1].waiting_caller)
agents[3].state = "idle"
handlers.agent_finished({ pane = 3, result = "done" }, cx)
assert(effects[#effects].target == 3 and effects[#effects].prompt == "move and wait")
assert(replies[move_cid].reply._ack and replies[move_cid].keep_open)
handlers.agent_finished({ pane = 3, result = "done" }, cx)
assert(replies[move_cid].reply.pane == 3 and replies[move_cid].reply.status == "done" and not replies[move_cid].keep_open)

-- A shell can inspect and manage the sole unowned live agent without creating a binding.
start()
local standalone = agents[2]
agents = { standalone }
standalone.state = "idle"
assert(rpc("queue", 1, nil, { action = "list" }).pane == 2)
assert(not rpc("queue", 2, nil, { action = "list" }).ok)
local ok, _, queued = radar_bridge.enqueue_prompt(cx, 2, "immediate")
assert(ok and queued == false and effects[#effects].prompt == "immediate")
local calls_after_immediate = #effects
local queued_ok, _, queued_flag, a, a_pos = radar_bridge.enqueue_prompt(cx, 2, "first pending")
assert(queued_ok and queued_flag and a_pos == 1 and #effects == calls_after_immediate)
local _, _, _, b = radar_bridge.enqueue_prompt(cx, 2, "second pending")
assert(radar_bridge.queue_prompt(b) == "second pending")
assert(radar_bridge.edit_queued(b, "edited pending"))
assert(radar_bridge.promote_queued(b))
local items = radar_bridge.queue_items(2)
assert(#items == 2 and items[1].id == b and items[1].preview == "edited pending")
assert(rpc("queue", 1, nil, { action = "edit", id = b, prompt = "edited from shell" }).ok)
assert(rpc("queue", 1, nil, { action = "reorder", ordered_ids = { a, b } }).ok)
assert(rpc("queue", 1, nil, { action = "move", id = b, to_pos = 1 }).ok)
assert(radar_bridge.cancel_queued_id(a))
assert(not radar_bridge.edit_queued(a, "stale") and not radar_bridge.cancel_queued_id(a))
assert(rpc("queue", 1, nil, { action = "cancel", position = 1 }).cancelled == 1)
assert(rpc("status", 2).owner_pane == nil and #radar_bridge.queue_items(2) == 0)
standalone.state = "waiting_input"
assert(not radar_bridge.enqueue_prompt(cx, 2, "blocked"))
standalone.state = "exited"
assert(not radar_bridge.enqueue_prompt(cx, 2, "exited"))
assert(not rpc("queue", 1, nil, { action = "list" }).ok)
standalone.state = "working"
local third_agent = { pane = 3, cwd = "/work", state = "idle" }
table.insert(agents, third_agent)
assert(not rpc("queue", 1, nil, { action = "list" }).ok)
table.remove(agents)

tab_tree = { pane = 2 }
assert(not radar_bridge.can_pip(cx, 2))
assert(not radar_bridge.pip(cx, 2))
local inner: TabTree = { split = "right", [1] = { pane = 2 }, [2] = { pane = 1 } }
local panel_leaf: TabTree = { pane = 4 }
tab_tree = { split = "right", [1] = panel_leaf, [2] = inner }
live_panel = 4
assert(radar_bridge.can_pip(cx, 2) and radar_bridge.pip(cx, 2))
assert(floated_over == 1, "standalone PiP should prefer the sibling shell over Wingman Live")
tab_tree = { split = "right", [1] = { pane = 4 }, [2] = { pane = 1 } }
focused_pane = 4
assert(radar_bridge.unpark(cx, 2))
assert(moved_next_to == 1, "unpark should place the standalone agent beside the shell instead of the focused sidebar")

local sync = rpc("dispatch", 1, 2, { async_callback = false, prompt = "waiting caller" })
local sync_cid = request_id
assert(sync._ack and sync.queued)
assert(radar_bridge.cancel_queued_id(sync.queue_id))
assert(replies[sync_cid].reply.status == "cancelled" and not replies[sync_cid].keep_open)

-- The panel's native queue view and move: live panes only, sorted, through the shared validated relocation.
start()
local busy_two = { pane = 2, cwd = "/work", state = "working" }
local target_three = { pane = 3, cwd = "/work", state = "idle" }
local busy_four = { pane = 4, cwd = "/work", state = "working" }
agents = { busy_two, target_three, busy_four }
local _, _, _, four_id = radar_bridge.enqueue_prompt(cx, 4, "four")
local _, _, _, two_a = radar_bridge.enqueue_prompt(cx, 2, "two a")
local _, _, _, two_b = radar_bridge.enqueue_prompt(cx, 2, "two b")
local overview = radar_bridge.all_queued(cx)
assert(#overview == 3 and overview[1].id == two_a and overview[1].pane == 2 and overview[1].position == 1)
assert(overview[2].id == two_b and overview[2].position == 2 and overview[3].id == four_id and overview[3].pane == 4)
panes[4] = nil
assert(#radar_bridge.all_queued(cx) == 2 and radar_bridge.all_queued(cx)[2].id == two_b)
panes[4] = { pane = 4, tab = 42, cwd = "/work" }

local before_native = #effects
local before_notice = notifications
target_three.state = "waiting_input"
local native_ok, native_err = radar_bridge.move_queued(cx, two_a, 3)
assert(not native_ok and string.find(native_err, "waiting_input", 1, true))
target_three.state = "exited"
assert(not radar_bridge.move_queued(cx, two_a, 3))
assert(not radar_bridge.move_queued(cx, two_a, 2) and not radar_bridge.move_queued(cx, 9999, 3))
assert(#effects == before_native and #radar_bridge.queue_items(2) == 2 and notifications == before_notice)
target_three.state = "working"
local deferred_ok, _, deferred = radar_bridge.move_queued(cx, two_a, 3)
assert(deferred_ok and deferred == false and #effects == before_native and radar_bridge.queue_items(3)[1].id == two_a)
assert(notifications > before_notice)
assert(radar_bridge.cancel_queued_id(two_a) and #radar_bridge.queue_items(3) == 0)
target_three.state = "idle"
local immediate_ok, immediate_err, immediate = radar_bridge.move_queued(cx, two_b, 3)
assert(immediate_ok and immediate_err == nil and immediate == true)
assert(effects[before_native + 1].target == 3 and effects[before_native + 1].prompt == "two b")
assert(rpc("status", 3).owner_pane == nil and (store.owners_v1 == nil or next(store.owners_v1) == nil),
    "moving an unowned queue must not create an ownership edge")

-- An owned queue keeps its supervisor: the unowned destination is adopted by that same owner.
start({ owners_v1 = { ["2"] = 1 } })
agents = { busy_two, target_three }
target_three.state = "idle"
local _, _, _, owned_item = radar_bridge.enqueue_prompt(cx, 2, "owned")
assert(radar_bridge.move_queued(cx, owned_item, 3) and rpc("status", 3).owner_pane == 1)
local advertised = rpc("status", 1).custom_agents
assert(#advertised == 3 and advertised[1] == "alpha.1" and advertised[2] == "bare" and advertised[3] == "zeta")
assert(select(2, radar_bridge.move_queued(cx, 9999, 3)) == "queue item 9999 is no longer queued (already dispatched or cancelled); run 'wingman queue list' to inspect current queue")

-- Tail-aware native surface reads, event preflight and escalation currency.
local tsp = real_require("./tsp")

local function has(text: any, needle: string): boolean
    return type(text) == "string" and string.find(text, needle, 1, true) ~= nil
end

local function assert_plain_json(value: any, path: string, ancestors: { [any]: boolean })
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return
    end
    assert(kind == "table", path .. " is a " .. kind)
    assert(not ancestors[value] and getmetatable(value) == nil, path .. " is cyclic or carries a metatable")
    ancestors[value] = true
    local length = #value
    local count = 0
    for key, child in value do
        count += 1
        assert(type(key) == "string" or (type(key) == "number" and key >= 1 and key <= length), path .. " has a non-JSON key")
        assert_plain_json(child, path .. "." .. tostring(key), ancestors)
    end
    assert(length == 0 or count == length, path .. " mixes array and object keys")
    ancestors[value] = nil
end

local function ask_count(pane: number): number
    local total = 0
    for _, entry in effects do
        if entry.op == "ask" and entry.target == pane then
            total += 1
        end
    end
    return total
end

local function last_ask(pane: number): string
    for index = #effects, 1, -1 do
        local entry = effects[index]
        if entry.op == "ask" and entry.target == pane then
            return entry.prompt or ""
        end
    end
    return ""
end

local function event_ids(from: number): { string }
    local ids: { string } = {}
    for index = from + 1, #effects do
        if effects[index].op == "event" then
            table.insert(ids, effects[index].prompt or "")
        end
    end
    return ids
end

-- Fires (and drops) the captured timers that were scheduled for exactly `ms`.
local function run_timers(ms: number): number
    local due: { (any) -> () } = {}
    local remaining: { { ms: number, callback: (any) -> () } } = {}
    for _, entry in timers do
        if entry.ms == ms then
            table.insert(due, entry.callback)
        else
            table.insert(remaining, entry)
        end
    end
    timers = remaining
    for _, callback in due do
        callback(cx)
    end
    return #due
end

-- Every table read stays inside Tern's node cap and, for the tail-aware paths, never scans the whole surface.
local function assert_bounded_reads(rooted_only: boolean)
    for index, call in mock.calls do
        if call.as == "table" then
            assert(type(call.nodes) == "number" and call.nodes >= 1 and call.nodes <= 5000, "read " .. index .. " has no bounded node budget")
            assert(call.depth == nil or (call.depth >= 0 and call.depth <= 64), "read " .. index .. " has an invalid depth")
            assert(not rooted_only or call.root ~= nil, "read " .. index .. " scanned the whole surface")
        end
    end
end

local function fleet(owners: { [string]: number }?, owner_state: string?): (any, any, any, any)
    agents = {
        { pane = 1, cwd = "/work", state = owner_state or "idle" },
        { pane = 2, cwd = "/work", state = "working" },
        { pane = 3, cwd = "/work", state = "idle" },
        { pane = 4, cwd = "/work", state = "idle" },
    }
    mock.surfaces, mock.absent, mock.calls = {}, {}, {}
    mock.rooted_reads, mock.rooted_wrapper, mock.missing_root_raises = true, false, false
    mock.event_failure, mock.on_event, mock.assistant_text = nil, nil, nil
    start(if owners then { owners_v1 = owners } else nil)
    return agents[1], agents[2], agents[3], agents[4]
end

local function ask_card(id: string, question: string, options: { string }): any
    local children: { any } = { node(id .. "-q", "text", { text = question }) }
    for index, label in options do
        table.insert(children, node(`{id}-opt-{index}`, "button", { label = label, actions = { click = "pick" } }))
    end
    table.insert(children, node(id .. ".actions/submit", "button", { label = "Submit", actions = { click = "submit" } }))
    return node(id, "card", { role = "omp.ask.card" }, children)
end

-- A transcript of 40 turns of 50 lines plus the live tail: far beyond one capped read, with an empty layer.
-- `nested` lands inside the final turn, `entries` become direct main entries after it.
local function long_surface(layout: { nested: { any }?, entries: { any }?, dock: any?, old_error: boolean? }): any
    local entries: { any } = {}
    for group = 1, 40 do
        local lines: { any } = {}
        for line = 1, 50 do
            table.insert(lines, node(`m{group}_{line}`, "text", { text = `history {group}.{line}` }))
        end
        if group == 3 and layout.old_error then
            table.insert(lines, node("old-error", "error", { role = "omp.error" }, { node("old-error-text", "text", { text = "Recovered earlier failure" }) }))
        end
        table.insert(entries, node(`g{group}`, "turn", nil, lines))
    end
    local last: { any } = {}
    for line = 1, 6 do
        table.insert(last, node(`t{line}`, "text", { text = `tail line {line}` }))
    end
    table.insert(last, node("t-final", "text", { text = "LAST-LINE-MARKER" }))
    for _, extra in ipairs(layout.nested or {}) do
        table.insert(last, extra)
    end
    table.insert(entries, node("g41", "turn", nil, last))
    for _, extra in ipairs(layout.entries or {}) do
        table.insert(entries, extra)
    end
    return {
        surface = { id = "surface-long", mode = "screen" },
        layer = node("layer", "layer", nil, nil),
        main = node("main", "chat", nil, entries),
        dock = layout.dock or node("dock", "dock", nil, nil),
    }
end

local function card_surface(): any
    return long_surface({ nested = {
        node("tail-content", "col", nil, { ask_card("ask-7", "Pick a database", { "PostgreSQL", "SQLite" }) }),
    } })
end

local function stall_entry(): any
    return node("err-9", "error", { role = "omp.error" }, { node("err-9-text", "text", { text = "Stream stalled: connection reset" }) })
end

local function retry_dock(): any
    return node("dock", "dock", nil, { node("hint", "text", { role = "omp.hint.retry", text = "F5 to retry" }) })
end

local function stall_surface(): any
    return long_surface({ entries = { stall_entry() }, dock = retry_dock() })
end

local function small_stall_surface(): any
    return {
        surface = { id = "surface-stall", mode = "screen" },
        main = node("main", "chat", nil, { node("context", "text", { text = "context" }), stall_entry() }),
        dock = retry_dock(),
    }
end

local function small_surface(card: any): any
    return {
        surface = { id = "surface-card", mode = "screen" },
        main = node("main", "chat", nil, { node("context", "text", { text = "context" }), card }),
    }
end

local function chained_card(number: number): any
    return ask_card("ask-" .. number, "Question " .. number, { "Yes " .. number, "No " .. number })
end

type Question = { prompt: string, options: { { label: string, detail: string? } }, open: boolean?, other: boolean?, selected: number? }

-- The real omp.ask.card layout: intro body, one group per question, an open question's list `<group>/f<n>` with o<n> items and `other`.
local function semantic_card(root: string, intro: string?, questions: { Question }): any
    local children: { any } = {}
    if intro ~= nil then
        table.insert(children, node(root .. ".body/intro", "col", nil, { node(root .. ".body/intro/p0", "text", { text = intro }) }))
    end
    for index, question in questions do
        local group = `{root}.g{index - 1}`
        local parts: { any } = { node(group .. "/q", "text", { text = question.prompt }) }
        if question.open ~= false then
            local items: { any } = {}
            for position, option in question.options do
                table.insert(items, node(`{group}/f{index - 1}/o{position - 1}`, "item", {
                    label = option.label, detail = option.detail, selected = question.selected == position or nil,
                }))
            end
            if question.other ~= false then
                table.insert(items, node(`{group}/f{index - 1}/other`, "item", { label = "Other" }))
            end
            table.insert(parts, node(`{group}/f{index - 1}`, "list", nil, items))
        else
            table.insert(parts, node(group .. "/fold", "card", { role = "omp.ask.fold" }, { node(group .. "/fold/t", "text", { text = "folded" }) }))
        end
        table.insert(children, node(group, "col", nil, parts))
    end
    table.insert(children, node(root .. ".actions/cancel", "button", { label = "Cancel", actions = { click = "cancel" } }))
    table.insert(children, node(root .. ".actions/submit", "button", { label = "Submit", actions = { click = "submit" } }))
    return node(root, "card", { role = "omp.ask.card" }, children)
end

local function approval_card(root: string, role: string, buttons: { string }): any
    local children: { any } = { node(root .. "/prompt", "text", { text = "Run rm -rf build?" }) }
    for _, click in buttons do
        table.insert(children, node(`{root}.actions/{click}`, "button", { label = click, actions = { click = click } }))
    end
    return node(root, "card", { role = role }, children)
end

-- The interactive card sits beyond what any single capped read returns; every runtime shape of a rooted read works.
for _, wrapper in { false, true } do
    local shape = if wrapper then "wrapper" else "direct"
    fleet({ ["2"] = 1 })
    mock.rooted_wrapper = wrapper
    local whole = card_surface()
    mock.surfaces[2] = whole

    local total = 0
    for _, region in SURFACE_REGIONS do
        total += count_nodes(whole[region])
    end
    assert(total > 2000, shape .. ": the mock transcript must exceed 2000 nodes")
    assert(select(2, locate(whole, "ask-7")) ~= nil)
    local capped = read_surface(2, { as = "table", nodes = 2000 })
    assert(select(2, locate(capped, "ask-7")) == nil, shape .. ": a capped whole-surface read must not reach the tail card")

    mock.calls = {}
    local shallow = tsp.read_root_node(cx, 2, "g41", { depth = 1, nodes = 100 })
    assert(shallow ~= nil and shallow.id == "g41" and #shallow.c == 8, shape .. ": shallow rooted read")
    assert(shallow.c[8].id == "tail-content" and shallow.c[8].more == 5 and shallow.c[8].c == nil, shape .. ": depth hides the nested card")
    local probe = tsp.read_root_node(cx, 2, "main", { depth = 0, nodes = 1 })
    assert(probe ~= nil and probe.id == "main" and probe.c == nil and probe.more > 2000, shape .. ": mounted probe stays one node")
    for _, raises in { false, true } do
        mock.missing_root_raises = raises
        assert(tsp.read_root_node(cx, 2, "ghost", { depth = 0, nodes = 1 }) == nil, shape .. ": missing node")
    end
    mock.missing_root_raises = false

    mock.surfaces[2] = long_surface({ nested = { node("tail-content", "col", nil, { semantic_card("ask-7", "Choosing storage", {
        { prompt = "Pick a database", options = { { label = "PostgreSQL", detail = "relational" }, { label = "SQLite" } }, selected = 2 },
    }) }) } })
    mock.calls = {}
    mock.assistant_text = string.rep("Long assistant prose. ", 400)
    local key, body = tsp.build_waiting_summary(cx, 2)
    assert(key == "omp.ask.card:ask-7", shape .. ": " .. key)
    assert(has(body, "Pick a database") and has(body, "PostgreSQL") and has(body, "SQLite"), shape .. ": card text reaches the owner")
    assert(has(body, "wingman answer --pane 2"), shape .. ": the owner gets the reply command")
    assert(not has(body, "ask-7") and not has(body, "click=") and not has(body, "Last assistant message") and not has(body, "Long assistant prose"), shape .. ": no node ids, chrome or assistant prose on a card: " .. body)
    assert(has(body, "Choosing storage") and has(body, "Q: Pick a database") and has(body, "1. PostgreSQL — relational") and has(body, "2. SQLite (selected)"), shape .. ": semantic question text: " .. body)
    assert(not has(body, "<svg") and not has(body, "g0") and not has(body, "actions/"), shape .. ": no svg or internal ids: " .. body)
    assert(not has(body, "(surface unavailable)"))
    assert_bounded_reads(true)

    mock.surfaces[2] = stall_surface()
    mock.calls = {}
    local faulted, fault_key, summary = tsp.inspect_fault_surface(cx, 2)
    assert(faulted and string.find(fault_key or "", "^fault:err%-9:") ~= nil, shape .. ": fault at the transcript tail")
    assert(has(summary, "Stream stalled: connection reset"), shape .. ": " .. tostring(summary))
    assert_bounded_reads(true)
    mock.surfaces[2] = long_surface({ entries = { node("abort-1", "text", { role = "omp.assistant.abort", text = "Aborted by user" }) } })
    assert(not tsp.inspect_fault_surface(cx, 2), shape .. ": a plain Esc abort is not a fault")
    mock.surfaces[2].dock = retry_dock()
    local dock_fault, _, dock_summary = tsp.inspect_fault_surface(cx, 2)
    assert(dock_fault and has(dock_summary, "Aborted by user"), shape .. ": a retry hint is active with a tail abort")
    mock.surfaces[2] = long_surface({ old_error = true })
    assert(not tsp.inspect_fault_surface(cx, 2), shape .. ": an old error above a clean tail is not a fault")

    -- The real window surface op: plain JSON replies, the live card, the explicit root and the tail fallback.
    mock.surfaces[2] = card_surface()
    mock.calls = {}
    local as_table = rpc("surface", 1, 2, { auto_root = true, as = "table" })
    assert(as_table.ok and as_table.root == "ask-7" and as_table.interactive_root == "ask-7", shape)
    assert(as_table.interactive_role == "omp.ask.card" and as_table.surface.id == "ask-7" and #as_table.surface.c == 4, shape)
    assert_plain_json(frame, shape .. " surface table", {})
    local as_text = rpc("surface", 1, 2, { auto_root = true })
    assert(as_text.ok and as_text.interactive_root == "ask-7" and type(as_text.surface) == "string", shape)
    assert(has(as_text.surface, "Pick a database") and has(as_text.surface, "click=pick"), shape .. ": " .. as_text.surface)
    assert_plain_json(frame, shape .. " surface text", {})
    assert_bounded_reads(true)
    local explicit = rpc("surface", 1, 2, { root = "ask-7", as = "table" })
    assert(explicit.ok and explicit.surface.id == "ask-7" and #explicit.surface.c == 4, shape)
    assert_plain_json(frame, shape .. " explicit root", {})
    local stale = rpc("surface", 1, 2, { root = "gone" })
    assert(not stale.ok and has(stale.error, '"gone"') and has(stale.error, "not found on pane 2"), shape)

    mock.surfaces[2] = long_surface({})
    mock.calls = {}
    local tail = rpc("surface", 1, 2, { auto_root = true })
    assert(tail.ok and tail.interactive_root == nil and tail.interactive_role == nil and tail.surface == nil and tail.state == "working", shape)
    assert(tail.root == nil, shape .. ": no scrollback without a card")
    assert_bounded_reads(true)
    local tail_table = rpc("surface", 1, 2, { auto_root = true, as = "table" })
    assert(tail_table.ok and tail_table.interactive_root == nil and tail_table.surface == nil, shape)
    assert_plain_json(frame, shape .. " quiet", {})
    mock.surfaces[2] = stall_surface()
    local fault = rpc("surface", 1, 2, { auto_root = true })
    assert(fault.ok and fault.interactive_role == "omp.fault" and has(fault.surface, "Stream stalled"), shape .. ": an active fault is still shown")

    mock.absent[2] = true
    local absent = rpc("surface", 1, 2, { auto_root = true })
    assert(absent.ok and absent.surface == nil and absent.interactive_root == nil, shape .. ": no surface mounted")
    assert_plain_json(frame, shape .. " absent", {})
end

-- A runtime without rooted reads falls back to one capped whole-surface read.
do
    fleet({ ["2"] = 1 })
    mock.rooted_reads = false
    mock.surfaces[2] = small_surface(ask_card("ask-7", "Pick a database", { "PostgreSQL", "SQLite" }))
    mock.calls = {}
    local key, body = tsp.build_waiting_summary(cx, 2)
    assert(key == "omp.ask.card:ask-7" and has(body, "PostgreSQL"), key)
    local fallback = rpc("surface", 1, 2, { auto_root = true })
    assert(fallback.ok and fallback.interactive_root == "ask-7" and has(fallback.surface, "Pick a database"))
    assert_bounded_reads(false)
    mock.surfaces[2] = small_stall_surface()
    assert(tsp.inspect_fault_surface(cx, 2), "faults on a small surface are found without rooted reads too")
end

-- Events: shape validation, mounted-node preflight against the live surface, and the batch stopping at the first failure.
for _, raises in { false, true } do
    fleet(nil)
    mock.missing_root_raises = raises
    local base = #effects

    local default_event = rpc("event", 1, 2)
    assert(default_event.ok and #default_event.results == 1 and default_event.results[1].ok, "the default `test` event mounts")
    assert(#effects == base + 1 and effects[#effects].op == "event" and effects[#effects].prompt == "test")
    assert_plain_json(frame, "event reply", {})
    assert(rpc("status", 2).owner_pane == 1, "a delivered event binds the answering owner")

    local ghost = { { ev = "action", id = "ghost", act = "submit" } }
    local missing = rpc("event", 1, 3, { events = ghost })
    assert(not missing.ok and has(missing.error, '"ghost"') and has(missing.error, "not found on pane 3") and has(missing.error, "no active interactive card"))
    assert(#missing.results == 1 and not missing.results[1].ok and #effects == base + 1, "a missing node sends nothing")
    assert(rpc("status", 3).owner_pane == nil, "a rejected event must not bind the target")
    assert_plain_json(frame, "missing reply", {})

    local malformed: { any } = { "oops", 42, {}, { ev = 7 }, { ev = "" } }
    for index, bad in malformed do
        local rejected = rpc("event", 1, 2, { events = { bad } })
        assert(not rejected.ok and has(rejected.error, "invalid event") and #effects == base + 1, "malformed event " .. index)
    end
    local empty = rpc("event", 1, 2, { events = {} })
    assert(not empty.ok and empty.error == "no events given" and #effects == base + 1)

    local keyed = rpc("event", 1, 2, { events = { { ev = "key", key = "Enter" } } })
    assert(keyed.ok and #effects == base + 2 and effects[#effects].prompt == nil, "an event without a node id needs no mounted node")

    local before_batch = #effects
    local stopped = rpc("event", 1, 2, { events = {
        { ev = "action", id = "test", act = "submit" },
        { ev = "action", id = "ghost", act = "submit" },
        { ev = "action", id = "test", act = "submit" },
    } })
    assert(not stopped.ok and #stopped.results == 2 and stopped.results[1].ok and not stopped.results[2].ok)
    assert(#event_ids(before_batch) == 1, "the batch stops at the first missing node")
    local mixed_events: { any } = { { ev = "action", id = "test", act = "submit" }, "oops", { ev = "action", id = "test", act = "submit" } }
    local after_malformed = rpc("event", 1, 2, { events = mixed_events })
    assert(not after_malformed.ok and #after_malformed.results == 2 and #event_ids(before_batch) == 2)

    mock.event_failure = "pane refused the event"
    local before_failure = #effects
    local failed = rpc("event", 1, 2, { events = { { ev = "action", id = "test", act = "submit" }, { ev = "action", id = "test", act = "submit" } } })
    assert(not failed.ok and has(failed.error, "pane refused the event") and #failed.results == 1 and #effects == before_failure)
    mock.event_failure = nil

    mock.absent[2] = true
    local none = rpc("event", 1, 2)
    assert(not none.ok and has(none.error, "no active TSP surface") and #effects == before_failure)
    mock.absent[2] = nil

    mock.surfaces[2] = small_surface(ask_card("40", "Pick one", { "A", "B" }))
    local submit = { ev = "action", id = "40.actions/submit", act = "submit" }
    local wrong = rpc("event", 1, 2, { events = { { ev = "action", id = "ui", act = "pick:0:0" }, submit } })
    assert(not wrong.ok and #wrong.results == 1 and wrong.results[1].error == wrong.error and #effects == before_failure)
    assert(has(wrong.error, [[surface node "ui" not found on pane 2 (active interactive root is "40", role omp.ask.card)]]))
    local correct = rpc("event", 1, 2, { events = { { ev = "action", id = "40", act = "pick:0:0" }, submit } })
    local answer_ids = event_ids(before_failure)
    assert(correct.ok and #answer_ids == 2 and answer_ids[1] == "40" and answer_ids[2] == "40.actions/submit")

    -- Dynamic ids: every event is checked against the surface as the previous event left it.
    mock.surfaces[2] = small_surface(chained_card(7))
    mock.on_event = function(pane: number, ev: any)
        local number = tonumber(string.match(tostring(ev.id), "^ask%-(%d+)%-opt"))
        if ev.act == "select" and number then
            mock.surfaces[pane] = small_surface(chained_card(number + 1))
        end
    end
    local before_dynamic = #effects
    local early = rpc("event", 1, 2, { events = { { ev = "action", id = "ask-8-opt-1", act = "select" } } })
    assert(not early.ok and has(early.error, [[active interactive root is "ask-7", role omp.ask.card]]) and #effects == before_dynamic)
    local chain = rpc("event", 1, 2, { events = {
        { ev = "action", id = "ask-7-opt-1", act = "select" },
        { ev = "action", id = "ask-8-opt-2", act = "select" },
        { ev = "action", id = "ask-9", act = "submit" },
    } })
    assert(chain.ok and #chain.results == 3)
    local sent = event_ids(before_dynamic)
    assert(#sent == 3 and sent[1] == "ask-7-opt-1" and sent[2] == "ask-8-opt-2" and sent[3] == "ask-9")
    assert_plain_json(frame, "chain reply", {})
    local answered = rpc("event", 1, 2, { events = { { ev = "action", id = "ask-7-opt-2", act = "select" } } })
    assert(not answered.ok and has(answered.error, [[active interactive root is "ask-9"]]), "a stale card id is rejected")

    mock.surfaces[2] = small_surface(chained_card(7))
    local before_stale = #effects
    local stale_batch = rpc("event", 1, 2, { events = {
        { ev = "action", id = "ask-7-opt-1", act = "select" },
        { ev = "action", id = "ask-7-opt-2", act = "select" },
    } })
    assert(not stale_batch.ok and #stale_batch.results == 2 and stale_batch.results[1].ok and not stale_batch.results[2].ok)
    assert(has(stale_batch.error, [[active interactive root is "ask-8"]]) and #event_ids(before_stale) == 1)
end

-- Escalation currency: queued waiting/fault escalations must reflect the live worker, turn completions must not.
local OWNED = { ["2"] = 1, ["3"] = 1, ["4"] = 1 }

local function ask_question(worker: any)
    worker.state = "waiting_input"
    handlers.agent_state({ pane = worker.pane, old = "working", new = "waiting_input" }, cx)
end

local function stall(worker: any)
    worker.state = "idle"
    handlers.agent_state({ pane = worker.pane, old = "working", new = "idle" }, cx)
end

local function resume(worker: any, from: string)
    worker.state = "working"
    handlers.agent_state({ pane = worker.pane, old = from, new = "working" }, cx)
end

local function owner_goes_idle(owner: any)
    owner.state = "idle"
    handlers.agent_state({ pane = owner.pane, old = "working", new = "idle" }, cx)
end

local function answer_card(pane: number, id: string)
    local out = rpc("event", 1, pane, { events = { { ev = "action", id = id, act = "submit" } } })
    assert(out.ok, tostring(out.error))
end

do -- a still-current waiting escalation is delivered once the owner is idle
    local owner, w2 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    ask_question(w2)
    assert(run_timers(120) == 1)
    assert(radar_bridge.queued_callbacks(1) == 1 and radar_bridge.notified_waiting(2) == "omp.ask.card:ask-7")
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before + 1 and radar_bridge.queued_callbacks(1) == 0)
    local prompt = last_ask(1)
    assert(has(prompt, "[Wingman waiting_input · pane 2]") and has(prompt, "Pick a database") and not has(prompt, "ask-7"), prompt)
end

do -- answer -> waiting -> working -> owner idle: the queued escalation is gone
    local owner, w2 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    ask_question(w2)
    assert(run_timers(120) == 1 and radar_bridge.queued_callbacks(1) == 1)
    local key = radar_bridge.notified_waiting(2)
    answer_card(2, "ask-7")
    assert(radar_bridge.queued_callbacks(1) == 0, "an answered card must leave the owner queue")
    assert(radar_bridge.notified_waiting(2) == key, "the card key stays until Tern leaves waiting_input")
    assert(rpc("status", 1).ok and w2.state == "waiting_input")
    assert(run_timers(120) == 1 and radar_bridge.queued_callbacks(1) == 0, "status must not requeue the answered card before Tern transitions")
    resume(w2, "waiting_input")
    assert(radar_bridge.notified_waiting(2) == nil)
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before, "a stale waiting escalation reached the owner")
end

do -- the escalation timer outlived the answer
    local owner, w2 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    ask_question(w2)
    answer_card(2, "ask-7")
    resume(w2, "waiting_input")
    assert(run_timers(120) == 1)
    assert(radar_bridge.queued_callbacks(1) == 0 and radar_bridge.notified_waiting(2) == nil)
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before)
end

do -- live filtering at flush: transitions Tern never reported, and a newer card replacing the queued one
    local owner, w2 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    ask_question(w2)
    assert(run_timers(120) == 1 and radar_bridge.queued_callbacks(1) == 1)
    w2.state = "idle"
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before and radar_bridge.queued_callbacks(1) == 0, "a worker that left waiting_input is dropped")

    owner, w2 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    ask_question(w2)
    assert(run_timers(120) == 1 and radar_bridge.queued_callbacks(1) == 1)
    mock.surfaces[2] = long_surface({ nested = { ask_card("ask-8", "Pick a cache", { "Redis", "None" }) } })
    handlers.agent_state({ pane = 2, old = "waiting_input", new = "waiting_input" }, cx)
    assert(run_timers(120) == 1 and radar_bridge.queued_callbacks(1) == 2)
    assert(radar_bridge.notified_waiting(2) == "omp.ask.card:ask-8")
    before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before + 1)
    local prompt = last_ask(1)
    assert(has(prompt, "Pick a cache") and not has(prompt, "Pick a database"), prompt)
end

do -- fault escalations: delivered while current, purged on retry, and pending timers invalidated
    local owner, _, _, w4 = fleet(OWNED, "working")
    mock.surfaces[4] = small_stall_surface()
    stall(w4)
    assert(run_timers(1500) == 1 and radar_bridge.queued_callbacks(1) == 1)
    assert(has(radar_bridge.fault(4), "Stream stalled"), tostring(radar_bridge.fault(4)))
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before + 1 and radar_bridge.queued_callbacks(1) == 0)
    local prompt = last_ask(1)
    assert(has(prompt, "[Wingman fault · retryable · pane 4]") and has(prompt, "Stream stalled") and has(prompt, "wingman retry --pane 4"), prompt)

    owner, _, _, w4 = fleet(OWNED, "working")
    mock.surfaces[4] = stall_surface()
    stall(w4)
    assert(run_timers(1500) == 1 and radar_bridge.queued_callbacks(1) == 1)
    resume(w4, "idle")
    assert(radar_bridge.queued_callbacks(1) == 0 and radar_bridge.notified_waiting(4) == nil, "a retried worker leaves no queued fault")
    before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before)

    owner, _, _, w4 = fleet(OWNED, "working")
    mock.surfaces[4] = stall_surface()
    stall(w4)
    assert(run_timers(1500) == 1 and radar_bridge.queued_callbacks(1) == 1)
    w4.state = "working"
    before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before and radar_bridge.queued_callbacks(1) == 0, "a fault whose worker moved on is dropped at flush")

    owner, _, _, w4 = fleet(OWNED, "working")
    mock.surfaces[4] = stall_surface()
    stall(w4)
    resume(w4, "idle")
    assert(run_timers(1500) == 1 and radar_bridge.queued_callbacks(1) == 0, "the settle timer must not escalate a resumed worker")

    owner, _, _, w4 = fleet(OWNED, "working")
    mock.surfaces[4] = stall_surface()
    w4.state = "idle"
    handlers.agent_finished({ pane = 4, result = "failed" }, cx)
    resume(w4, "idle")
    assert(run_timers(150) == 1 and radar_bridge.queued_callbacks(1) == 0 and radar_bridge.notified_waiting(4) == nil, "the failed-turn timer is invalidated by a retry")
    stall(w4)
    w4.state = "idle"
    handlers.agent_finished({ pane = 4, result = "failed" }, cx)
    assert(run_timers(150) == 1 and radar_bridge.queued_callbacks(1) == 1, "an unretried failed turn still escalates")
end

do -- real turn completions survive every purge; stale waiting/fault entries do not
    local owner, w2, w3, w4 = fleet(OWNED, "working")
    mock.surfaces[2] = card_surface()
    mock.surfaces[4] = stall_surface()
    ask_question(w2)
    assert(run_timers(120) == 1)
    stall(w4)
    assert(run_timers(1500) == 1)
    resume(w3, "idle")
    w3.state = "idle"
    w3.last_message = "build ok"
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    assert(radar_bridge.queued_callbacks(1) == 3, "waiting, fault and turn entries queue behind the busy owner")
    resume(w3, "idle")
    assert(radar_bridge.queued_callbacks(1) == 3, "starting the next turn must not drop the finished one")
    answer_card(2, "ask-7")
    assert(radar_bridge.queued_callbacks(1) == 2)
    resume(w2, "waiting_input")
    resume(w4, "idle")
    assert(radar_bridge.queued_callbacks(1) == 1, "only the real turn completion remains")
    w3.state = "idle"
    local before = ask_count(1)
    owner_goes_idle(owner)
    assert(ask_count(1) == before + 1 and radar_bridge.queued_callbacks(1) == 0)
    local prompt = last_ask(1)
    assert(has(prompt, "[Wingman auto-callback · done · pane 3]") and has(prompt, "build ok"), prompt)
    assert(not has(prompt, "ask-7") and not has(prompt, "Stream stalled"), prompt)
end

-- wingman answer: the real handler driven through the fixture session.
local seen: { any } = {}
local function record_events(extra: ((number, any) -> ())?)
    seen = {}
    mock.on_event = function(pane: number, ev: any)
        table.insert(seen, ev)
        if extra then
            extra(pane, ev)
        end
    end
end

local function answer(extra: { [string]: any }): any
    local copy: { [string]: any } = { choices = {} }
    for key, value in extra do
        copy[key] = value
    end
    return rpc("answer", 1, 2, copy)
end

local function answer_pending(extra: { [string]: any }): number
    frame = nil
    request_id += 1
    request = { op = "answer", anchor_pane = 1, target_pane = 2, async_callback = true, choices = {} }
    for key, value in extra do
        request[key] = value
    end
    receive("request", cx)
    return request_id
end

local function ev_acts(): { string }
    local out: { string } = {}
    for _, ev in seen do
        table.insert(out, `{ev.ev}:{ev.id}:{ev.act or ev.item or ""}`)
    end
    return out
end

local function surface_with(card: any)
    mock.surfaces[2] = small_surface(card)
end

local THREE: Question = { prompt = "Pick a database", options = { { label = "PostgreSQL" }, { label = "SQLite" }, { label = "MySQL" } } }

do -- single and multi-question picks
    fleet(nil)
    record_events()
    surface_with(semantic_card("ask-7", nil, { THREE }))
    local out = answer({ choices = { 2 } })
    assert(out.ok and out.root == nil and #out.results == 2, tostring(out.error))
    local acts = ev_acts()
    assert(#acts == 2 and acts[1] == "action:ask-7:pick:0:1" and acts[2] == "action:ask-7.actions/submit:submit", table.concat(acts, " | "))
    assert_plain_json(frame, "answer reply", {})
    assert(rpc("status", 2).owner_pane == 1, "a delivered answer binds the owner")

    surface_with(semantic_card("ask-7", "Setup", { THREE, { prompt = "Pick a cache", options = { { label = "Redis" }, { label = "None" } } } }))
    record_events()
    out = answer({ choices = { 1, 2 } })
    acts = ev_acts()
    assert(out.ok and #acts == 3 and acts[1] == "action:ask-7:pick:0:0" and acts[2] == "action:ask-7:pick:1:1" and acts[3] == "action:ask-7.actions/submit:submit", table.concat(acts, " | "))
    record_events()
    out = answer({ choices = { 1, 3 }, question = 1 })
    acts = ev_acts()
    assert(out.ok and acts[1] == "action:ask-7:pick:0:0" and acts[2] == "action:ask-7:pick:0:2" and acts[3] == "action:ask-7.actions/submit:submit", table.concat(acts, " | "))
    record_events()
    out = answer({ choices = { 2 }, question = 2 })
    acts = ev_acts()
    assert(out.ok and acts[1] == "action:ask-7:pick:1:1" and #acts == 2, table.concat(acts, " | "))
end

do -- invalid answers fire nothing and bind nothing
    fleet(nil)
    record_events()
    surface_with(semantic_card("ask-7", nil, { THREE }))
    for index, bad in { { 0 }, { 4 }, { 9 } } do
        local out = answer({ choices = bad })
        assert(not out.ok and has(out.error or "", "choice"), "invalid choices " .. index .. ": " .. tostring(out.error))
        assert(#seen == 0, "invalid choices " .. index .. " must not reach the pane")
    end
    assert(rpc("status", 2).owner_pane == nil, "a rejected answer must not bind the owner")
    mock.surfaces[2] = long_surface({})
    local none = answer({ choices = { 1 } })
    assert(not none.ok and has(none.error or "", "no active interactive prompt on pane 2") and #seen == 0, tostring(none.error))
    mock.absent[2] = true
    local absent = answer({ cancel = true })
    assert(not absent.ok and #seen == 0)
end

do -- approve / deny / cancel
    for _, role in { "omp.overlay.approval", "omp.editor.ask.approval" } do
        fleet(nil)
        record_events()
        surface_with(approval_card("appr-1", role, { "approve", "deny" }))
        local out = answer({ approve = true })
        local acts = ev_acts()
        assert(out.ok and #acts == 1 and acts[1] == "action:appr-1.actions/approve:approve", role .. " " .. table.concat(acts, " | "))
        record_events()
        out = answer({ deny = true })
        acts = ev_acts()
        assert(out.ok and #acts == 1 and acts[1] == "action:appr-1.actions/deny:deny", role .. " " .. table.concat(acts, " | "))
    end
    fleet(nil)
    record_events()
    surface_with(semantic_card("ask-7", nil, { THREE }))
    local out = answer({ cancel = true })
    local acts = ev_acts()
    assert(out.ok and #acts == 1 and acts[1] == "action:ask-7.actions/cancel:cancel", table.concat(acts, " | "))
end

local OTHER_TEXT = "héllo 😀"
local OTHER_UTF16 = 8

local function input_node(): any
    return node("ask-7.g0/input", "input", { value = "" })
end

do -- Other with the list and input already mounted
    fleet(nil)
    record_events()
    surface_with(semantic_card("ask-7", nil, { THREE }))
    local card = mock.surfaces[2].main.c[2]
    table.insert(card.c[1].c, input_node())
    local out = answer({ other = OTHER_TEXT })
    assert(out.ok, tostring(out.error))
    assert(#seen == 4, table.concat(ev_acts(), " | "))
    assert(seen[1].ev == "action" and seen[1].id == "ask-7" and seen[1].act == "open:0")
    assert(seen[2].ev == "select" and seen[2].id == "ask-7.g0/f0" and seen[2].item == "other")
    local edit = seen[3]
    assert(edit.ev == "edit" and edit.id == "ask-7.g0/input" and edit.text == OTHER_TEXT and edit.from == 0 and edit.to == 0 and edit.len == 0, "edit event")
    assert(edit.cursor == OTHER_UTF16, "cursor counts UTF-16 units, got " .. tostring(edit.cursor))
    assert(seen[4].ev == "action" and seen[4].id == "ask-7.actions/submit" and seen[4].act == "submit")
    assert(rpc("status", 2).owner_pane == 1)
end

do -- Other when the list and the input mount 60ms late
    fleet(nil)
    record_events()
    local card = semantic_card("ask-7", nil, { THREE })
    local group = card.c[1]
    local list = table.remove(group.c, 2)
    surface_with(card)
    local cid = answer_pending({ other = OTHER_TEXT, question = 1 })
    assert(replies[cid] == nil, "the reply waits for the late list")
    assert(#seen == 1 and seen[1].act == "open:0", table.concat(ev_acts(), " | "))
    assert(radar_bridge.queued_callbacks(1) == 0 and rpc("status", 3).ok)
    table.insert(group.c, list)
    assert(run_timers(60) == 1)
    assert(#seen == 2 and seen[2].ev == "select" and seen[2].item == "other", table.concat(ev_acts(), " | "))
    assert(replies[cid] == nil, "the reply waits for the late input")
    table.insert(group.c, input_node())
    assert(run_timers(60) == 1)
    assert(replies[cid] and replies[cid].reply.ok, "delayed Other completes")
    assert(#seen == 4 and seen[3].ev == "edit" and seen[3].cursor == OTHER_UTF16 and seen[3].text == OTHER_TEXT)
    assert(seen[4].act == "submit")
    assert(rpc("status", 2).owner_pane == 1, "rearm only after the final success")

    fleet(nil)
    record_events()
    local late = semantic_card("ask-7", nil, { THREE })
    table.remove(late.c[1].c, 2)
    surface_with(late)
    answer_pending({ other = "x" })
    assert(frame == nil)
    assert(run_timers(60) == 1)
    assert(frame and frame.reply and not frame.reply.ok, "a list that never mounts fails the answer")
    assert(#seen == 1 and rpc("status", 2).owner_pane == nil, "a failed Other binds nothing")
end

do -- a completion keeps its conclusion when a chart precedes it
    local owner, _, w3 = fleet(OWNED, "working")
    resume(w3, "idle")
    local chart = '```svg\n<svg aria-label="latency"><rect width="9"/></svg>\n```\n'
    w3.state = "idle"
    w3.last_message = chart .. "Final conclusion: ship it"
    mock.assistant_text = w3.last_message
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    owner_goes_idle(owner)
    local prompt = last_ask(1)
    assert(has(prompt, "[chart: latency]") and has(prompt, "Final conclusion: ship it") and not has(prompt, "<svg") and not has(prompt, "<rect"), prompt)
end

-- Composer telemetry and thinking control: bounded TSP reads, scoped status, ordered effects, promotion re-resolution.
local EFFORT_ID = "j.bar/model/effort"

local function composer_nodes(prefix: string, context: string, level: string): { any }
    return {
        node(prefix .. ".context", "meter", { role = "omp.composer.context", label = context }),
        node(prefix .. ".bar/model/effort", "effort", { role = "omp.composer.model.effort", level = level }),
    }
end

local function composer_surface(context: string, level: string): any
    return {
        surface = { id = "surface-composer", mode = "screen" },
        main = node("main", "chat", nil, composer_nodes("j", context, level)),
    }
end

local function root_reads(prefix: string): { SurfaceCall }
    local hits: { SurfaceCall } = {}
    for _, call in mock.calls do
        if type(call.root) == "string" and string.sub(call.root, 1, #prefix) == prefix then
            table.insert(hits, call)
        end
    end
    return hits
end

local function effect_ops(from: number): { string }
    local ops: { string } = {}
    for index = from + 1, #effects do
        table.insert(ops, effects[index].op .. ":" .. effects[index].target)
    end
    return ops
end

local function record_thinking_events(): { any }
    local log: { any } = {}
    mock.on_event = function(pane: number, ev: any)
        table.insert(log, { pane = pane, ev = ev })
    end
    return log
end

do -- bounded reads: fast path, last-editor fallback, and no fallback after a fast hit
    fleet(nil)
    mock.surfaces[2] = composer_surface("20%", "low")
    mock.calls = {}
    local context, level, control = tsp.read_composer_telemetry(cx, 2)
    assert(context == "20%" and level == "low" and control == EFFORT_ID)
    assert(#mock.calls == 2 and #root_reads("dock") == 0)
    for _, call in mock.calls do
        assert(call.depth == 0 and call.nodes == 1, "fast reads request exactly one node")
    end
    assert_bounded_reads(true)

    local first = composer_nodes("e1", "5%", "high")
    local last_editor_nodes = composer_nodes("e2", "61%", "medium")
    local editors = node("dock", "dock", nil, {
        node("e1", "editor", { role = "omp.editor" }),
        node("e2", "editor", { role = "omp.editor" }),
    })
    mock.surfaces[2] = {
        surface = { id = "surface-dock", mode = "screen" },
        main = node("main", "chat", nil, { first[1], first[2], last_editor_nodes[1], last_editor_nodes[2] }),
        dock = editors,
    }
    mock.calls = {}
    local fallback_context, fallback_level, fallback_control = tsp.read_composer_telemetry(cx, 2)
    assert(fallback_context == "61%" and fallback_level == "medium" and fallback_control == "e2.bar/model/effort", "the reverse scan picks the last editor")
    assert(#root_reads("e1") == 0 and #root_reads("dock") == 1)
    local dock_call = root_reads("dock")[1]
    assert(#mock.calls == 5 and dock_call.depth == 2 and dock_call.nodes == 64)
    assert_bounded_reads(true)

    mock.surfaces[2].dock = node("dock", "dock", nil, {
        node("tray", "col", { role = "omp.tray" }, { node("task", "row") }),
        node("wrapper", "col", nil, {
            node("e1", "editor", { role = "omp.editor" }),
            node("e2", "editor", { role = "omp.editor" }),
        }),
    })
    mock.calls = {}
    local nested_context, nested_level, nested_control = tsp.read_composer_telemetry(cx, 2)
    assert(nested_context == "61%" and nested_level == "medium" and nested_control == "e2.bar/model/effort")
    assert(#mock.calls == 5 and #root_reads("e1") == 0, "nested fallback still probes only the latest editor")

    mock.surfaces[2] = {
        surface = { id = "surface-fast", mode = "screen" },
        main = node("main", "chat", nil, { composer_nodes("j", "7%", "low")[1], first[1], first[2] }),
        dock = editors,
    }
    mock.calls = {}
    local partial_context, partial_level, partial_control = tsp.read_composer_telemetry(cx, 2)
    assert(partial_context == "7%" and partial_level == nil and partial_control == nil)
    assert(#root_reads("dock") == 0 and #root_reads("e") == 0, "a single fast node hit never falls back")

    mock.rooted_wrapper = true
    mock.surfaces[2] = {
        main = node("main", "chat", nil, {
            node("j.context", "custom", { role = "omp.composer.context", label = "not a percentage", value = 0.146 }),
            node(EFFORT_ID, "custom", { role = "omp.composer.model.effort", level = "  auto  " }),
        }),
    }
    local numeric_context, trimmed_level, wrapped_control = tsp.read_composer_telemetry(cx, 2)
    assert(numeric_context == "15%" and trimmed_level == "auto" and wrapped_control == EFFORT_ID)
    mock.surfaces[2].main.c[1] = node("j.context", "text", { label = "50%" })
    mock.surfaces[2].main.c[2] = node(EFFORT_ID, "effort", { level = "   " })
    local invalid_context, blank_level, mounted_control = tsp.read_composer_telemetry(cx, 2)
    assert(invalid_context == nil and blank_level == nil and mounted_control == EFFORT_ID)
end

do -- status telemetry is scoped to the caller's own, owner and unowned same-tab agents
    fleet({ ["2"] = 1, ["4"] = 3 })
    for pane = 1, 4 do
        agents[pane].state = "working"
        mock.surfaces[pane] = composer_surface(`{pane}0%`, "low")
    end
    mock.calls = {}
    local status = rpc("status", 1)
    local rows: { [number]: any } = {}
    for _, row in status.agents do
        rows[row.pane] = row
    end
    assert(rows[2].context == "20%" and rows[2].thinking == "low", "a bound worker reports telemetry")
    assert(rows[3].context == "30%", "an unowned agent in the caller's tab reports telemetry")
    assert(rows[1].context == nil and rows[4].context == nil and rows[4].thinking == nil, "self and others' workers stay unread")
    for _, call in root_reads("j.") do
        assert(call.pane == 2 or call.pane == 3, "unscoped telemetry read of pane " .. call.pane)
    end
    assert_bounded_reads(false)

    local all = rpc("status", 1, nil, { all = true })
    for _, row in all.agents do
        assert(row.context ~= nil, "status --all reads every live agent: pane " .. row.pane)
    end
    local from_worker = rpc("status", 2)
    for _, row in from_worker.agents do
        if row.pane == 1 or row.pane == 3 then
            assert(row.context ~= nil, "a worker sees its owner and unowned peers: pane " .. row.pane)
        else
            assert(row.context == nil, "a worker does not read itself or foreign workers: pane " .. row.pane)
        end
    end
    agents[3].state = "exited"
    assert(rpc("status", 1).agents[3].context == nil)
    assert_plain_json(frame, "status telemetry", {})
end

do -- immediate dispatch: validation first, then thinking.set before ask, no effects when rejected
    fleet(nil)
    mock.surfaces[3] = composer_surface("20%", "low")
    local log = record_thinking_events()
    local base = #effects
    local invalid = rpc("dispatch", 1, 3, { thinking = "bogus" })
    assert(not invalid.ok and #effects == base and rpc("status", 3).owner_pane == nil)
    assert(not rpc("dispatch", 1, 3, { thinking = 5 }).ok and #effects == base)
    local unsupported = rpc("dispatch", 1, 4, { thinking = "high" })
    assert(not unsupported.ok and has(unsupported.error, "thinking control") and #effects == base)
    assert(rpc("status", 4).owner_pane == nil)

    assert(rpc("dispatch", 1, 3, { thinking = "high" }).ok)
    local ops = effect_ops(base)
    assert(#ops == 2 and ops[1] == "event:3" and ops[2] == "ask:3", table.concat(ops, ","))
    local event = log[1].ev
    assert(event.ev == "action" and event.id == EFFORT_ID and event.act == "thinking.set" and event.value == "high")
    local before = #effects
    assert(rpc("dispatch", 1, 4).ok and #effects == before + 1, "a dispatch without thinking never sets")
end

do -- queued: no mid-turn event, control re-resolved at promotion
    local _, _, w3 = fleet(nil)
    mock.surfaces[3] = composer_surface("20%", "low")
    local log = record_thinking_events()
    w3.state = "working"
    local base = #effects
    local first_dispatch = rpc("dispatch", 1, 3, { thinking = "xhigh", prompt = "first" })
    assert(first_dispatch.ok and first_dispatch.queued and #log == 0 and #effects == base, "no event while the pane is mid-turn")
    w3.state = "idle"
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    local ops = effect_ops(base)
    assert(#ops == 2 and ops[1] == "event:3" and ops[2] == "ask:3", table.concat(ops, ","))
    assert(log[1].ev.value == "xhigh" and last_ask(3) == "first")

    w3.state = "working"
    local next_dispatch = rpc("dispatch", 1, 3, { thinking = "off", prompt = "second" })
    assert(next_dispatch.ok and next_dispatch.queued)
    mock.surfaces[3] = nil
    mock.absent[3] = true
    local before_ask = ask_count(3)
    local before_events = #log
    w3.state = "idle"
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    assert(ask_count(3) == before_ask and #log == before_events, "an unsupported pane at promotion sends nothing")
    assert(#radar_bridge.queue_items(3) == 0)
end

do -- moved: rejected before mutating, then applied at the destination in order
    fleet(nil)
    mock.surfaces[2] = composer_surface("20%", "low")
    local log = record_thinking_events()
    local queued_thinking = rpc("dispatch", 1, 2, { thinking = "medium", prompt = "carry" })
    assert(queued_thinking.ok and queued_thinking.queued)
    local base = #effects
    local unsupported_move = queue_rpc("move", { id = queued_thinking.queue_id, to_pane = 3 })
    assert(not unsupported_move.ok and has(unsupported_move.error, "thinking control") and #effects == base and #log == 0)
    assert(#radar_bridge.queue_items(2) == 1 and #radar_bridge.queue_items(3) == 0, "a rejected move leaves the queue untouched")
    assert(not radar_bridge.move_queued(cx, queued_thinking.queue_id, 3) and #radar_bridge.queue_items(2) == 1)
    assert(rpc("status", 3).owner_pane == nil)

    mock.surfaces[3] = composer_surface("30%", "low")
    local supported_move = queue_rpc("move", { id = queued_thinking.queue_id, to_pane = 3 })
    assert(supported_move.ok and supported_move.dispatched)
    local ops = effect_ops(base)
    assert(#ops == 2 and ops[1] == "event:3" and ops[2] == "ask:3", table.concat(ops, ","))
    assert(log[1].ev.value == "medium" and last_ask(3) == "carry")
end

do -- completion paths do not read or expose composer telemetry
    fleet(nil)
    mock.surfaces[3] = composer_surface("20%", "low")
    local sync_dispatch = rpc("dispatch", 1, 3, { async_callback = false })
    local cid = request_id
    assert(sync_dispatch._ack)
    handlers.agent_state({ pane = 3, old = "idle", new = "working" }, cx)
    agents[3].state = "idle"
    mock.calls = {}
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    local reply = replies[cid].reply
    assert(reply.status == "done" and reply.context == nil and reply.thinking == nil)
    assert_plain_json(frame, "completion", {})
    local awaited = rpc("await", 1, 3)
    assert(awaited.status == "done" and awaited.context == nil and awaited.thinking == nil)
    assert(#mock.calls == 0, "finish_wait and immediate await require no surface reads")

    local owner, _, w3 = fleet(OWNED, "working")
    mock.surfaces[3] = composer_surface("20%", "low")
    resume(w3, "idle")
    w3.state = "idle"
    w3.last_message = "telemetry ok"
    mock.calls = {}
    handlers.agent_finished({ pane = 3, result = "done" }, cx)
    owner_goes_idle(owner)
    assert(last_ask(1) == "[Wingman auto-callback · done · pane 3]\ntelemetry ok", last_ask(1))
    assert(#root_reads("j.") == 0, "completion callbacks do not probe composer nodes")
end
