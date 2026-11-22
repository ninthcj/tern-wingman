--!strict
-- The Python test copies state.luau and tsp.luau beside the generated script and injects window.luau here,
-- so the real mux handler and real modules run under stock Luau. Only Tern's outer API, the live panel
-- and mux byte transport are replaced.
local handlers: { [string]: (any) -> () } = {}
local effects: { { op: string, target: number } } = {}
local store: { [string]: any } = {}
local frame: any
local request: { [string]: any }
local receive: (string, any) -> ()
local function unexpected(message: any)
    error(tostring(message), 2)
end
local tern = {
    runtime = { os = "macos" },
    plugin = { dir = "." },
    getenv = function() return nil end,
    now = function() return 0 end,
    timer = function() end,
    command = function() end,
    on = function(event, callback) handlers[event] = callback end,
    log = { error = unexpected, warn = unexpected },
    kv = {
        set = function(key, value) store[key] = value end,
        get = function(key) return store[key] end,
    },
    json = {
        array = function(rows) return rows or {} end,
        encode = function(value) frame = value; return "reply" end,
        decode = function() return { id = 1, req = request } end,
    },
    process = {
        spawn = function(_, options)
            receive = options.stdout
            return { write = function() end }
        end,
    },
}
local notifications = 0
local real_require = require
local function fixture_require(path: string): any
    if path == "./radar" then
        return { on_state_change = function() notifications += 1 end, attach = function() end }
    end
    return real_require(path)
end
local function load_plugin(require: (string) -> any)
-- @WINDOW_PLUGIN@
end

local function effect(op: string, target: number)
    table.insert(effects, { op = op, target = target })
end
local panes = {}
local agents = {}
for id = 1, 4 do
    panes[id] = { pane = id, tab = 42, cwd = "/work" }
    agents[id] = { pane = id, cwd = "/work", state = "idle" }
end
local cx = {
    window_key = function() return "" end,
    session = {
        pane = function(_, id) return panes[id] end,
        tab_of = function(_, id) return panes[id].tab end,
        layout = function() return { floats = {} } end,
        surface = function() return nil end,
        event = function(_, pane) effect("event", pane) end,
    },
    agents = {
        list = function() return agents end,
        ask = function(_, pane) effect("ask", pane) end,
        transcript = function() return {} end,
    },
    layout = {
        float = function(_, pane) effect("pip", pane); return true end,
        dock = function(_, pane) effect("dock", pane); return true end,
    },
}
local function rpc(op: string, anchor: number, target: number?, extra: { [string]: any }?): any
    frame = nil
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
