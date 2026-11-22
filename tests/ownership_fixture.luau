-- The Python test injects window.luau here so the real mux handler runs under stock Luau.
-- Only Tern's outer API and mux byte transport are replaced.
local handlers, effects = {}, {}
local store = {}
local frame, request, receive
local function unexpected(message)
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
local function require()
    return { on_state_change = function() end, attach = function() end }
end
local function load_plugin()
-- @WINDOW_PLUGIN@
end

local function effect(op, target)
    table.insert(effects, { op, target })
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
local function rpc(op, anchor, target)
    frame = nil
    request = { op = op, anchor_pane = anchor, target_pane = target, prompt = "hello", async_callback = true,
        events = { { ev = "action", id = "test", act = "submit" } } }
    receive("request", cx)
    assert(frame and frame.reply, op .. " did not reply")
    return frame.reply
end
local function start(data)
    store = data or {}
    load_plugin()
    handlers.window_start(cx)
end
local function assert_cycle(op, anchor, target)
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
