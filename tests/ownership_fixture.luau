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
local cx = {
    window_key = function() return "" end,
    session = {
        pane = function(_, id) return panes[id] end,
        tab_of = function(_, id) return panes[id].tab end,
        layout = function() return { floats = {}, root = tab_tree, tab = 42 } end,
        focused = function() return focused_pane end,
        surface = function() return nil end,
        event = function(_, pane) effect("event", pane) end,
    },
    canvas = {
        list = function()
            return if live_panel then { { pane = live_panel, title = "Wingman Live", owner = "wingman" } } else {}
        end,
    },
    agents = {
        list = function() return agents end,
        ask = function(_, pane, prompt) effect("ask", pane, prompt) end,
        transcript = function() return {} end,
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
