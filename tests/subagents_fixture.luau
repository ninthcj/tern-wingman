--!nonstrict
-- Pure fixture for subagents.luau, run directly (`luau tests/subagents_fixture.luau`): it loads the real module and
-- drives it through a fake native driver, asserting detection, keys and titles, the 1500 ms open debounce, the 20 s
-- finished grace, pinning, dismissal, reuse, the window-wide limit, finished-slot reuse and explicit `more` at a full
-- window, per-parent formation anchors, the reconcile budget, unavailable-canvas and failed-update retries, and the
-- pure placement rule.
local subagents = require("../subagents")

local function check(condition: any, message: string)
    if not condition then
        error(message, 2)
    end
end

local function expect(actual: any, expected: any, label: string)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

local function contains(list: any, value: any): boolean
    return table.find(list, value) ~= nil
end

-- A subagent tool card as the transcript reports it; `fields` override or extend the defaults.
local function tool(key: string, status: string, fields: any?)
    local card = { key = key, name = "task", status = status, intent = "do " .. key }
    for field, value in fields or {} do
        card[field] = value
    end
    return card
end

-- A card with exactly the given fields (plus a running status unless it names one).
local function raw(fields: any)
    local card = { status = "running" }
    for field, value in fields do
        card[field] = value
    end
    return card
end

local function message(...)
    return { role = "assistant", text = "", tools = { ... } }
end

-- One message holding all the cards.
local function sample(...)
    return { message(...) }
end

local function fresh(limit: number)
    return subagents.new({ enabled = true, limit = limit })
end

local function make_driver()
    local d = { next_pane = 100, open_nil = false, open_throw = false, update_ok = true, records = {} }
    local function reset()
        d.log, d.opened, d.updates, d.closed, d.focused = {}, {}, {}, {}, {}
    end
    reset()
    d.reset = reset
    d.count = function(kind: string): number
        local n = 0
        for _, entry in d.log do
            if entry == kind then
                n += 1
            end
        end
        return n
    end
    d.driver = {
        open = function(record, previous, unlimited, overflow)
            table.insert(d.log, "open")
            if d.open_throw then
                d.open_throw = false
                error("native open failed")
            end
            if d.open_nil then
                return nil
            end
            d.next_pane += 1
            d.records[d.next_pane] = record
            table.insert(d.opened, { pane = d.next_pane, record = record, previous = previous, unlimited = unlimited, overflow = overflow })
            return d.next_pane
        end,
        update = function(pane, record, pinned, overflow)
            table.insert(d.log, "update")
            table.insert(d.updates, { pane = pane, record = record, pinned = pinned, overflow = overflow })
            if not d.update_ok then
                return false
            end
            d.records[pane] = record
            return true
        end,
        close = function(pane)
            table.insert(d.log, "close")
            table.insert(d.closed, pane)
            d.records[pane] = nil
        end,
        focus = function(parent)
            table.insert(d.log, "focus")
            table.insert(d.focused, parent)
        end,
    }
    return d
end

local ELIGIBLE = { [1] = true, [2] = true, [3] = true }

-- Placement: first below at .34, later to the right at .5, an unlimited row wraps down below .16 of the tab.
do
    local function place(previous: number?, share: number?, unlimited: boolean, target: number, direction: string, ratio: number, label: string)
        local got_target, got_direction, got_ratio = subagents.placement(7, previous, share, unlimited)
        expect(got_target, target, label .. " target")
        expect(got_direction, direction, label .. " direction")
        expect(got_ratio, ratio, label .. " ratio")
    end
    place(nil, nil, false, 7, "down", 0.34, "first")
    place(nil, 0.1, true, 7, "down", 0.34, "first ignores unlimited and share")
    place(12, 0.5, false, 12, "right", 0.5, "second")
    place(12, nil, true, 12, "right", 0.5, "unknown share never wraps")
    place(12, 0.2, false, 12, "right", 0.5, "limited rows never wrap")
    place(12, 0.32, true, 12, "right", 0.5, "half a share of exactly .16 still fits")
    place(12, 0.31, true, 12, "down", 0.5, "unlimited wraps below .16")
end

-- Config: defaults, sanitizing, copies and the limit cycle.
do
    local off = subagents.new(nil).config()
    expect(off.enabled, false, "off by default")
    expect(off.limit, 3, "default limit")
    for label, raw_config in {
        { enabled = "yes", limit = -1 },
        { limit = 99 },
        { limit = "5" },
        { limit = 0 / 0 },
        "junk",
    } do
        local config = subagents.new(raw_config).config()
        expect(config.enabled, false, "unusable config " .. tostring(label) .. " enabled")
        expect(config.limit, 3, "unusable config " .. tostring(label) .. " limit")
    end
    local on = subagents.new({ enabled = true, limit = 2.7 }).config()
    expect(on.enabled, true, "enabled kept")
    expect(on.limit, 2, "limit floors")
    expect(subagents.new({ limit = 0 }).config().limit, 0, "0 is unlimited")

    local sub = subagents.new(nil)
    local copy = sub.config()
    copy.limit = 7
    copy.enabled = true
    expect(sub.config().limit, 3, "config() hands out a copy (limit)")
    expect(sub.config().enabled, false, "config() hands out a copy (enabled)")
    sub.toggle()
    expect(sub.config().enabled, true, "toggle on")
    sub.toggle()
    expect(sub.config().enabled, false, "toggle off")

    local seen = {}
    for _ = 1, 5 do
        sub.cycle_limit()
        table.insert(seen, sub.config().limit)
    end
    expect(table.concat(seen, ","), "2,4,0,1,3", "limit cycle 3 -> 2 -> 4 -> 0 -> 1 -> 3")
    expect(sub.config().enabled, false, "cycling leaves enabled alone")
    local function cycled(start: number): number
        local other = subagents.new({ limit = start })
        other.cycle_limit()
        return other.config().limit
    end
    expect(cycled(5), 3, "an off-cycle limit restarts the cycle")
    expect(cycled(10), 3, "another off-cycle limit restarts the cycle")
end

-- Lifecycle: 1500 ms debounce, reuse of one pane, preserved start, 20 s grace, no reopening, no duplicates.
do
    local sub, d = fresh(3), make_driver()
    expect(sub.observe(1, "Parent A", 3, sample(tool("k1", "running")), 1000), 1, "depth of the only running call")
    expect(sub.next_expiry(), nil, "no debounce timer: the radar already ticks while an agent works")
    expect(sub.reconcile(1000, ELIGIBLE, d.driver), false, "nothing to do is not deferral")
    expect(sub.reconcile(2499, ELIGIBLE, d.driver), false, "before the debounce")
    expect(#d.log, 0, "no pane before 1500 ms")
    expect(sub.reconcile(2500, ELIGIBLE, d.driver), false, "opening is not deferral")
    expect(table.concat(d.log, ","), "open", "opens exactly at 1500 ms")
    local opened = d.opened[1]
    local pane = opened.pane
    expect(opened.previous, nil, "first pane has no predecessor")
    expect(opened.unlimited, false, "limited window")
    expect(opened.overflow, 0, "nothing overflows")
    local record = opened.record
    expect(record.id, "1|k1", "id is parent|tool key")
    expect(record.parent_pane, 1, "parent pane")
    expect(record.parent_title, "Parent A", "parent title")
    expect(record.parent_hue, 3, "parent hue")
    expect(record.title, "do k1", "title")
    expect(record.status, "running", "status")
    expect(record.started_ms, 1000, "start is the first sighting")
    expect(record.finished_ms, nil, "still running")
    expect(record.took, nil, "no duration while running")
    expect(table.isfrozen(record) and table.isfrozen(record.badges), true, "records are frozen")
    check(contains(record.badges, "task"), "the tool name is a badge")
    expect(sub.next_expiry(), nil, "open and running: nothing time-based due")

    d.reset()
    sub.observe(1, "Parent A", 3, sample(tool("k1", "running", { text = "halfway" })), 3000)
    sub.reconcile(3000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "same call reuses its pane")
    expect(d.updates[1].pane, pane, "update targets the same pane")
    expect(d.updates[1].record.text, "halfway", "new content")
    expect(d.updates[1].record.started_ms, 1000, "start timestamp preserved")
    local repainted = d.updates[1].record
    d.reset()
    sub.observe(1, "Parent A", 3, sample(tool("k1", "running", { text = "halfway" })), 3000)
    sub.reconcile(3000, ELIGIBLE, d.driver)
    sub.reconcile(3999, ELIGIBLE, d.driver)
    expect(#d.log, 0, "unchanged content and timer step send nothing")
    sub.reconcile(4000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "a new timer step repaints once")
    expect(d.updates[1].record, repainted, "timer repaint resends the same frozen record")

    d.reset()
    sub.observe(1, "Parent A", 3, sample(tool("k1", "done", { took = 3500, text = "halfway" })), 5000)
    sub.reconcile(5000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "completion repaints")
    expect(d.records[pane].status, "done", "finished status")
    expect(d.records[pane].finished_ms, 5000, "finish time")
    expect(d.records[pane].took, 3500, "reported duration")
    expect(d.records[pane].started_ms, 1000, "start still preserved")
    expect(sub.next_expiry(), 25000, "grace expiry is finish + 20 s")
    d.reset()
    sub.reconcile(24999, ELIGIBLE, d.driver)
    expect(#d.log, 0, "pane lingers through the grace")
    sub.reconcile(25000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "close", "closes when the grace ends")
    expect(d.closed[1], pane, "closes the right pane")
    expect(sub.next_expiry(), nil, "nothing left to expire")

    d.reset()
    sub.observe(1, "Parent A", 3, sample(tool("k1", "done")), 26000)
    sub.reconcile(26000, ELIGIBLE, d.driver)
    sub.observe(1, "Parent A", 3, {}, 27000)
    sub.observe(1, "Parent A", 3, sample(tool("k1", "done")), 28000)
    sub.reconcile(28000, ELIGIBLE, d.driver)
    expect(#d.log, 0, "a finished call never reopens, even after leaving and re-entering the transcript")
end

-- A call that finishes inside the debounce never gets a pane.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(tool("quick", "running")), 1000)
    sub.observe(1, "P", 1, sample(tool("quick", "done")), 2000)
    sub.reconcile(2000, ELIGIBLE, d.driver)
    sub.reconcile(3000, ELIGIBLE, d.driver)
    expect(#d.log, 0, "short call: no pane")
    local unseen = fresh(3)
    unseen.observe(1, "P", 1, sample(tool("gone", "running")), 1000)
    unseen.observe(1, "P", 1, {}, 1200)
    unseen.reconcile(3000, ELIGIBLE, d.driver)
    expect(#d.log, 0, "a call that left the transcript before opening never opens")
end

-- Eligibility enables new pop-outs only; it never closes an open pane.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running")), 1000)
    sub.reconcile(2500, { [1] = false }, d.driver)
    sub.reconcile(2500, {}, d.driver)
    expect(#d.log, 0, "ineligible parent opens nothing")
    sub.reconcile(2600, { [1] = true }, d.driver)
    expect(d.count("open"), 1, "eligible parent opens")
    d.reset()
    sub.reconcile(2700, { [1] = false }, d.driver)
    sub.reconcile(2800, {}, d.driver)
    expect(d.count("close"), 0, "losing eligibility leaves open panes alone")
    sub.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running")), 2900)
    sub.reconcile(4500, { [1] = false }, d.driver)
    expect(d.count("open"), 0, "a new call of an ineligible parent still waits")
end

-- Detection, keys and title priority.
do
    local sub, d = fresh(12), make_driver()
    sub.observe(1, "P1", 7, sample(
        raw({ key = "a", name = "Task", intent = "Intent!", target = "T", title = "Ti" }),
        raw({ key = "b", name = "agent", target = "Target B", title = "Ti" }),
        raw({ key = "c", name = "SubAgent", title = "Title C" }),
        raw({ key = "d", name = "invoke_subagent" }),
        raw({ key = "e", name = "bash" }),
        raw({ key = "f", name = "read", role = "omp.tool.task" }),
        raw({ key = "g", name = "tool", title = "Agent" }),
        raw({ key = "s", name = "task", target = { { t = "Span" }, { t = " Ten" } } }),
        raw({ key = "h", name = "x", role = "OMP.TOOL.TASK" }),
        raw({ key = "i", name = "bash", role = "omp.tool.bash" })
    ), 1000)
    sub.observe(2, "P2", 9, sample(raw({ key = "a", name = "task", intent = "other parent" })), 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    local by_id = {}
    for _, opened in d.opened do
        by_id[opened.record.id] = opened.record
    end
    expect(#d.opened, 9, "nine subagent calls open")
    for id, title in {
        ["1|a"] = "Intent!",
        ["1|b"] = "Target B",
        ["1|c"] = "Title C",
        ["1|d"] = "invoke_subagent",
        ["1|f"] = "read",
        ["1|g"] = "Agent",
        ["1|s"] = "Span Ten",
        ["1|h"] = "x",
        ["2|a"] = "other parent",
    } do
        check(by_id[id] ~= nil, "missing record " .. id)
        expect(by_id[id].title, title, "title of " .. id)
    end
    expect(by_id["1|e"], nil, "bash is not a subagent")
    expect(by_id["1|i"], nil, "another tool role is not a subagent")
    expect(by_id["1|a"].parent_title, "P1", "record carries its parent title")
    expect(by_id["2|a"].parent_hue, 9, "record carries its parent hue")
    check(contains(by_id["1|a"].badges, "Task"), "badge keeps the tool's own name")
    expect(d.opened[1].previous, nil, "first has no predecessor")
    for index = 2, 8 do
        expect(d.opened[index].previous, d.opened[index - 1].pane, "each pane is placed after its own parent's last opened")
    end
    expect(d.opened[9].record.id, "2|a", "the other parent opens last")
    expect(d.opened[9].previous, nil, "another parent's pane is never the predecessor")
    expect(d.opened[1].overflow, 0, "a pane that is followed by more opens shows no overflow")
    expect(d.opened[9].overflow, 0, "nothing waits after the last")

    local metadata = fresh(3)
    local md = make_driver()
    metadata.observe(1, "P", 1, sample(raw({ key = "m", name = "task", metadata = { agent = "explore", model = "fast" } })), 1000)
    metadata.reconcile(2500, ELIGIBLE, md.driver)
    local badges = md.opened[1].record.badges
    check(contains(badges, "explore") and contains(badges, "fast") and contains(badges, "task"), "metadata badges")

    local long = fresh(3)
    local ld = make_driver()
    long.observe(1, string.rep("é", 100), 1, sample(raw({ key = "l", name = "task", intent = string.rep("é", 100), text = string.rep("ü", 2000) })), 1000)
    long.reconcile(2500, ELIGIBLE, ld.driver)
    local clipped = ld.opened[1].record
    check(utf8.len(clipped.title) ~= nil and #clipped.title <= 99 and string.sub(clipped.title, -3) == "…", "title clips on a character boundary")
    check(utf8.len(clipped.parent_title) ~= nil and #clipped.parent_title <= 99, "parent title clips on a character boundary")
    check(utf8.len(clipped.text) ~= nil and #clipped.text < 2000, "text is clipped")
end

-- Cards without a key collapse into one pane that survives a filling-in target.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(raw({ name = "task", intent = "no key" })), 1000)
    sub.observe(1, "P", 1, sample(raw({ name = "task", intent = "no key", target = "appeared" })), 1500)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    expect(d.count("open"), 1, "same keyless call: one pane")
    expect(d.opened[1].record.title, "no key", "intent still wins")
    sub.observe(1, "P", 1, sample(raw({ name = "task", intent = "no key", target = "appeared" })), 3000)
    sub.reconcile(3000, ELIGIBLE, d.driver)
    expect(d.count("open"), 1, "re-sampling never duplicates it")
    sub.observe(1, "P", 1, sample(raw({ name = "task", intent = "no key" }), raw({ name = "task", intent = "different" })), 3100)
    sub.reconcile(4700, ELIGIBLE, d.driver)
    expect(d.count("open"), 2, "a different keyless call is another pane")
end

-- observe reports the depth of the oldest running subagent card.
do
    local sub = fresh(3)
    local depth = sub.observe(1, "P", 1, {
        message(raw({ key = "x", name = "task", status = "done" })),
        message(),
        message(raw({ key = "bash", name = "bash" }), raw({ key = "y", name = "task" })),
        message(raw({ key = "z", name = "task" })),
    }, 1000)
    expect(depth, 2, "four messages, oldest running subagent at message 3")
    expect(sub.observe(1, "P", 1, sample(raw({ key = "x", name = "task", status = "done" }), raw({ key = "b", name = "bash" })), 1100), 0, "nothing running")
    expect(sub.observe(1, "P", 1, {}, 1200), 0, "empty sample")
end

-- Pins survive a lowered limit and fill the cap, dismissal sticks, a full window never displaces a running call on
-- its own, a finished slot is reused at once, and `more` rotates waiting calls through an unpinned slot.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P1", 7, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "running")), 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    expect(d.count("open"), 3, "three panes at limit 3")
    local p1, p2, p3 = d.opened[1].pane, d.opened[2].pane, d.opened[3].pane
    expect(d.opened[1].previous, nil, "first pane of a parent")
    expect(d.opened[2].previous, p1, "second follows the first")
    expect(d.opened[3].previous, p2, "third follows the second")
    for index = 1, 3 do
        expect(d.opened[index].overflow, 0, "nothing waits")
    end
    expect(sub.action(p1, "pin", 2600, d.driver), true, "pin k1")
    expect(d.updates[#d.updates].pinned, true, "pin is pushed to the pane")
    expect(sub.action(p2, "pin", 2600, d.driver), true, "pin k2")
    expect(sub.action(9999, "pin", 2600, d.driver), false, "unknown pane")
    expect(sub.action(p3, "bogus", 2600, d.driver), false, "unknown action")

    for _ = 1, 4 do
        sub.cycle_limit()
    end
    expect(sub.config().limit, 1, "limit lowered to 1")
    d.reset()
    sub.reconcile(2700, ELIGIBLE, d.driver)
    expect(table.concat(d.closed, ","), tostring(p3), "lowering closes the unpinned pane and keeps both pins")
    sub.observe(1, "P1", 7, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "done")), 2800)

    sub.observe(2, "P2", 2, sample(tool("k4", "running")), 3000)
    d.reset()
    sub.reconcile(5000, ELIGIBLE, d.driver)
    expect(d.count("open") + d.count("close"), 0, "pinned panes alone exceed the cap: nothing opens")
    sub.cycle_limit()
    expect(sub.config().limit, 3, "limit raised to 3")
    sub.reconcile(5100, ELIGIBLE, d.driver)
    expect(d.count("open"), 1, "a free slot opens the waiting call")
    expect(d.opened[1].record.id, "2|k4", "the waiting call")
    expect(d.opened[1].previous, nil, "no pane of another parent is its predecessor")
    local p4 = d.opened[1].pane

    expect(sub.pane_closed(p1), true, "user closes a pinned pane")
    expect(sub.pane_closed(p1), false, "no longer ours")
    sub.observe(1, "P1", 7, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "done")), 5300)
    d.reset()
    sub.reconcile(5300, ELIGIBLE, d.driver)
    expect(d.count("open"), 0, "dismissed and closed calls stay closed")

    sub.observe(3, "P3", 5, sample(tool("k5", "running")), 6000)
    d.reset()
    sub.reconcile(7600, ELIGIBLE, d.driver)
    expect(d.opened[1].record.id, "3|k5", "the third parent opens its own pane")
    expect(d.opened[1].previous, nil, "formation anchors are per parent")
    local p5 = d.opened[1].pane

    -- The window is full (k2 pinned, k4, k5): a new call waits; nothing running is displaced.
    sub.observe(1, "P1", 7, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "done"), tool("k6", "running")), 8000)
    d.reset()
    sub.reconcile(9600, ELIGIBLE, d.driver)
    expect(d.count("open") + d.count("close"), 0, "a full window opens and closes nothing")
    local counted = false
    for _, update in d.updates do
        check(update.record.id ~= "1|k6", "a running call is never displaced automatically")
        if update.pane == p5 and update.overflow == 1 then
            counted = true
        end
    end
    check(counted, "the last unpinned slot shows how many calls wait")

    expect(sub.action(p2, "more", 9700, d.driver), false, "a pinned slot is never rotated")
    expect(sub.action(p5, "more", 9700, d.driver), true, "more shows the waiting call")
    local shown = d.updates[#d.updates]
    expect(shown.pane, p5, "in place")
    expect(shown.record.id, "1|k6", "the waiting call")
    expect(shown.pinned, false, "unpinned")
    expect(shown.overflow, 1, "the displaced running call now waits")
    d.reset()
    expect(sub.action(p5, "parent", 9710, d.driver), true, "parent action")
    expect(table.concat(d.focused, ","), "1", "Parent focuses the parent of the record now shown")
    expect(sub.action(p5, "more", 9800, d.driver), true, "more again rotates back")
    expect(d.updates[#d.updates].record.id, "3|k5", "the displaced call returns")
    expect(d.count("open"), 0, "rotation never opens panes")

    -- A finished unpinned slot is reused by a waiting call without waiting for its grace.
    sub.observe(1, "P1", 7, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "running"), tool("k6", "running")), 10000)
    sub.observe(2, "P2", 2, sample(tool("k4", "done")), 10000)
    sub.observe(3, "P3", 5, sample(tool("k5", "running")), 10000)
    d.reset()
    sub.reconcile(10000, ELIGIBLE, d.driver)
    local reused
    for _, update in d.updates do
        if update.pane == p4 then
            reused = update
        end
    end
    check(reused ~= nil and reused.record.id == "1|k6", "the finished slot takes the waiting call in place")
    expect(d.count("open") + d.count("close"), 0, "no pane churn")
end

-- At a one-slot window: running calls keep the slot; each finished slot is handed on at once; the grace only
-- matters for the last one.
do
    local sub, d = fresh(1), make_driver()
    local function all(k1: string, k2: string, k3: string)
        return sample(tool("k1", k1), tool("k2", k2), tool("k3", k3))
    end
    sub.observe(1, "P", 1, all("running", "running", "running"), 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "open", "first call takes the only slot")
    local pane = d.opened[1].pane
    expect(d.opened[1].overflow, 2, "two more wait")
    expect(sub.next_expiry(), nil, "no rotation timer")

    d.reset()
    sub.reconcile(60000, ELIGIBLE, d.driver)
    for _, update in d.updates do
        expect(update.record.id, "1|k1", "only the timer repaints; the running call keeps its slot")
    end
    expect(d.count("open") + d.count("close"), 0, "no churn")
    expect(sub.next_expiry(), nil, "still no timer")

    d.reset()
    sub.observe(1, "P", 1, all("done", "running", "running"), 61000)
    sub.reconcile(61000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "the finished slot goes straight to the next call")
    expect(d.updates[1].pane, pane, "same slot")
    expect(d.updates[1].record.id, "1|k2", "next call")
    expect(d.updates[1].overflow, 1, "k3 still waits")

    d.reset()
    sub.observe(1, "P", 1, all("done", "done", "running"), 62000)
    sub.reconcile(62000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "and on to the last")
    expect(d.updates[1].record.id, "1|k3", "k3 shown")
    expect(d.updates[1].overflow, 0, "nothing waits")

    d.reset()
    sub.observe(1, "P", 1, all("done", "done", "done"), 63000)
    sub.reconcile(63000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "update", "k3 finishing repaints")
    expect(sub.next_expiry(), 83000, "only a finished slot's grace is an expiry")
    d.reset()
    sub.reconcile(83000, ELIGIBLE, d.driver)
    expect(table.concat(d.log, ","), "close", "closes after the grace")
    expect(sub.next_expiry(), nil, "nothing left")
end

-- Unlimited: the driver is told, and no cap applies.
do
    local sub, d = fresh(0), make_driver()
    local cards = {}
    for index = 1, 6 do
        table.insert(cards, tool("u" .. index, "running"))
    end
    sub.observe(1, "P", 1, { { role = "assistant", text = "", tools = cards } }, 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    expect(#d.opened, 6, "limit 0 opens every call")
    for _, opened in d.opened do
        expect(opened.unlimited, true, "driver told the window is unlimited")
    end
end

-- Budget: each native mutation asks first; true means deferred work, and idle calls never ask.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "running")), 1000)
    local asked = 0
    local function stop_after_first(): boolean
        asked += 1
        return asked >= 2
    end
    expect(sub.reconcile(2500, ELIGIBLE, d.driver, stop_after_first), true, "budget exhausted: work deferred")
    expect(d.count("open"), 1, "one mutation fit the budget")
    expect(sub.reconcile(2500, ELIGIBLE, d.driver, nil), false, "next call finishes")
    expect(d.count("open"), 3, "all opened in the end")
    expect(d.opened[2].overflow, 0, "a pane followed by another open shows no overflow")
    expect(d.count("update"), 0, "no pane is repainted for a count that never showed")

    d.reset()
    sub.observe(1, "P", 1, sample(tool("k1", "running", { text = "more" }), tool("k2", "running"), tool("k3", "running")), 2600)
    expect(sub.reconcile(2600, ELIGIBLE, d.driver, function(): boolean return true end), true, "an update is a mutation too")
    expect(d.count("update"), 0, "deferred update not sent")
    expect(sub.reconcile(2600, ELIGIBLE, d.driver, nil), false, "update goes through next call")
    expect(d.count("update"), 1, "update sent once")

    local idle, id = fresh(3), make_driver()
    local idle_asks = 0
    expect(idle.reconcile(1000, ELIGIBLE, id.driver, function(): boolean
        idle_asks += 1
        return true
    end), false, "idle reconcile is not deferral")
    expect(idle_asks, 0, "no mutation, no question")
end

-- Unavailable canvas and driver errors never spin or retry forever.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running")), 1000)
    d.open_nil = true
    expect(sub.reconcile(2500, ELIGIBLE, d.driver), false, "unavailable canvas is not deferral")
    expect(d.count("open"), 1, "one attempt, not one per call")
    expect(sub.next_expiry(), nil, "no timer is requested for a missing canvas")
    d.open_nil = false
    expect(sub.reconcile(2600, ELIGIBLE, d.driver), false, "canvas back")
    expect(#d.opened, 2, "both open once the canvas answers")

    local boom, bd = fresh(3), make_driver()
    boom.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running")), 1000)
    bd.open_throw = true
    check(not pcall(boom.reconcile, 2500, ELIGIBLE, bd.driver), "driver error reaches the caller")
    expect(boom.reconcile(2600, ELIGIBLE, bd.driver), false, "recovers")
    expect(#bd.opened, 1, "only the other call opens")
    expect(bd.opened[1].record.id, "1|k2", "the call whose open threw is not retried")
    boom.reconcile(2700, ELIGIBLE, bd.driver)
    expect(#bd.opened, 1, "still not retried")

    local flaky, fd = fresh(3), make_driver()
    flaky.observe(1, "P", 1, sample(tool("k1", "running")), 1000)
    flaky.reconcile(2500, ELIGIBLE, fd.driver)
    fd.reset()
    fd.update_ok = false
    flaky.observe(1, "P", 1, sample(tool("k1", "running", { text = "a" })), 2600)
    expect(flaky.reconcile(2600, ELIGIBLE, fd.driver), false, "failed update is not deferral")
    expect(flaky.reconcile(2650, ELIGIBLE, fd.driver), false, "still failing")
    expect(fd.count("update"), 2, "a failed update is retried, not memoized")
    fd.update_ok = true
    flaky.reconcile(2700, ELIGIBLE, fd.driver)
    expect(fd.count("update"), 3, "retry lands")
    flaky.reconcile(2750, ELIGIBLE, fd.driver)
    expect(fd.count("update"), 3, "then it is remembered")
end

-- Dismissal: closing a pane or pressing close keeps the call closed.
do
    local sub, d = fresh(3), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running")), 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    local pane = d.opened[1].pane
    expect(sub.action(pane, "close", 2600, d.driver), true, "close action")
    expect(table.concat(d.closed, ","), tostring(pane), "driver closes it")
    expect(sub.pane_closed(pane), false, "already released")
    sub.observe(1, "P", 1, sample(tool("k1", "running")), 5000)
    sub.observe(1, "P", 1, {}, 5100)
    sub.observe(1, "P", 1, sample(tool("k1", "running")), 5200)
    sub.reconcile(9000, ELIGIBLE, d.driver)
    expect(d.count("open"), 1, "a dismissed running call stays closed, even across a gap in the sample")
    sub.parent_closed(1, d.driver)
    sub.observe(1, "P", 1, sample(tool("k1", "running")), 10000)
    sub.reconcile(11600, ELIGIBLE, d.driver)
    expect(d.count("open"), 2, "the marker ends with its parent")
end

-- Toggling off stops new panes and closes unpinned ones; pins stay.
do
    local sub, d = subagents.new(nil), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running")), 1000)
    expect(sub.next_expiry(), nil, "disabled: no expiry")
    sub.reconcile(2500, ELIGIBLE, d.driver)
    expect(#d.log, 0, "disabled opens nothing")
    sub.toggle()
    sub.reconcile(2600, ELIGIBLE, d.driver)
    expect(d.count("open"), 2, "enabled opens")
    local p1, p2 = d.opened[1].pane, d.opened[2].pane
    sub.action(p1, "pin", 2700, d.driver)
    d.reset()
    sub.toggle()
    sub.reconcile(2800, ELIGIBLE, d.driver)
    expect(table.concat(d.closed, ","), tostring(p2), "disabling closes the unpinned pane only")
end

-- Finishing and closing parents; missing calls.
do
    local sub, d = fresh(8), make_driver()
    sub.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running"), tool("k3", "running")), 1000)
    sub.reconcile(2500, ELIGIBLE, d.driver)
    local p1, p2, p3 = d.opened[1].pane, d.opened[2].pane, d.opened[3].pane
    sub.action(p2, "pin", 2600, d.driver)
    sub.finish_parent(1, "error", 4000)
    d.reset()
    sub.reconcile(4000, ELIGIBLE, d.driver)
    expect(d.records[p1].status, "error", "parent finished with error")
    expect(d.records[p1].took, 3000, "duration from the preserved start")
    expect(d.records[p1].finished_ms, 4000, "finished when the parent did")
    sub.observe(1, "P", 1, sample(tool("k1", "done"), tool("k2", "done"), tool("k3", "done")), 4100)
    sub.reconcile(4100, ELIGIBLE, d.driver)
    expect(d.records[p1].status, "done", "the card's own final status replaces the inferred one")
    expect(d.records[p1].finished_ms, 4000, "finish time kept")
    d.reset()
    sub.reconcile(24000, ELIGIBLE, d.driver)
    expect(table.concat(d.closed, ","), p1 .. "," .. p3, "grace closes unpinned panes; the pin stays")
    sub.parent_closed(1, d.driver)
    expect(table.concat(d.closed, ","), p1 .. "," .. p3 .. "," .. p2, "closing the parent closes its pinned slot too")
    expect(sub.pane_closed(p2), false, "already released")
    expect(sub.action(p2, "parent", 24100, d.driver), false, "the slot is gone")

    local run, rd = fresh(3), make_driver()
    run.observe(1, "P", 1, sample(tool("k1", "running"), tool("k2", "running")), 1000)
    run.reconcile(2500, ELIGIBLE, rd.driver)
    local q1, q2 = rd.opened[1].pane, rd.opened[2].pane
    run.action(q1, "pin", 2600, rd.driver)
    rd.reset()
    run.parent_closed(1, rd.driver)
    expect(table.concat(rd.closed, ","), q1 .. "," .. q2, "closing the parent closes every slot formed for it, pinned too")
    rd.reset()
    run.reconcile(2700, ELIGIBLE, rd.driver)
    expect(#rd.log, 0, "nothing of that parent is left to open or repaint")

    -- A slot formed for a dead parent that shows another parent's running call: the call waits for a slot again.
    local shared, sd = fresh(2), make_driver()
    shared.observe(1, "P1", 1, sample(tool("a1", "running")), 1000)
    shared.observe(2, "P2", 2, sample(tool("b1", "running")), 1000)
    shared.observe(3, "P3", 3, sample(tool("c1", "running")), 1000)
    shared.reconcile(2500, ELIGIBLE, sd.driver)
    expect(#sd.opened, 2, "two panes at limit 2")
    expect(sd.opened[2].previous, nil, "P2's pane does not follow P1's")
    local pb = sd.opened[2].pane
    expect(shared.action(pb, "more", 2600, sd.driver), true, "P3's call takes P2's slot")
    expect(sd.updates[#sd.updates].record.id, "3|c1", "shown in place")
    sd.reset()
    shared.parent_closed(2, sd.driver)
    expect(table.concat(sd.closed, ","), tostring(pb), "the slot formed for P2 closes though it shows P3's call")
    shared.reconcile(2700, ELIGIBLE, sd.driver)
    expect(#sd.opened, 1, "the displaced call reopens")
    expect(sd.opened[1].record.id, "3|c1", "P3's call")
    expect(sd.opened[1].previous, nil, "in a formation of its own")

    -- A slot formed for a live parent that shows a dead parent's call closes too.
    local mixed, md = fresh(2), make_driver()
    mixed.observe(1, "P1", 1, sample(tool("a1", "running")), 1000)
    mixed.observe(2, "P2", 2, sample(tool("b1", "running"), tool("b2", "running")), 1000)
    mixed.reconcile(2500, ELIGIBLE, md.driver)
    local pa, pb2 = md.opened[1].pane, md.opened[2].pane
    expect(mixed.action(pa, "more", 2600, md.driver), true, "P2's second call takes P1's slot")
    md.reset()
    mixed.parent_closed(2, md.driver)
    expect(table.concat(md.closed, ","), pb2 .. "," .. pa, "both slots close: one formed for P2, one showing its call")
    mixed.reconcile(2700, ELIGIBLE, md.driver)
    expect(#md.opened, 1, "P1's displaced call reopens")
    expect(md.opened[1].record.id, "1|a1", "P1's call")
    expect(md.opened[1].previous, nil, "nothing of its formation is left")

    -- Interleaved parents keep separate formation anchors.
    local rows, rd2 = fresh(8), make_driver()
    rows.observe(1, "P1", 1, sample(tool("a1", "running"), tool("a2", "running")), 1000)
    rows.observe(2, "P2", 2, sample(tool("b1", "running")), 1000)
    rows.reconcile(2500, ELIGIBLE, rd2.driver)
    local ra2 = rd2.opened[2].pane
    rows.observe(1, "P1", 1, sample(tool("a1", "running"), tool("a2", "running"), tool("a3", "running")), 3000)
    rd2.reset()
    rows.reconcile(4500, ELIGIBLE, rd2.driver)
    expect(rd2.opened[1].record.id, "1|a3", "P1's third call")
    expect(rd2.opened[1].previous, ra2, "follows P1's last pane, not P2's")

    local lost, ld = fresh(3), make_driver()
    lost.observe(1, "P", 1, sample(tool("k1", "running")), 1000)
    lost.reconcile(2500, ELIGIBLE, ld.driver)
    local pane = ld.opened[1].pane
    lost.observe(1, "P", 1, {}, 3000)
    lost.reconcile(3000, ELIGIBLE, ld.driver)
    expect(ld.records[pane].status, "done", "a running call missing from the sample is finished")
    expect(ld.records[pane].finished_ms, 3000, "when it was noticed")
    check(contains(ld.records[pane].badges, "lost"), "marked lost")
    expect(lost.next_expiry(), 23000, "and lingers through the grace")
end

do
    local sub, d = subagents.new({ enabled = true }), make_driver()
    sub.observe(1, "Parent", 1, sample(tool("first", "running")), 0)
    sub.reconcile(1500, ELIGIBLE, d.driver)
    local pane = d.opened[1].pane
    sub.observe(1, "Parent", 1, sample(tool("first", "done"),
        raw({ key = "second", name = "execute", title = "Subagent", status = "running", badges = { "background", { text = "2 agents" } } })), 2000)
    d.reset()
    sub.reconcile(3500, ELIGIBLE, d.driver)
    expect(d.count("open") + d.count("close"), 0, "reuse finished slot even below capacity")
    expect(d.records[pane].id, "1|second", "title matches across harnesses")
    check(contains(d.records[pane].badges, "background") and contains(d.records[pane].badges, "2 agents"), "transcript badges preserved")
    sub.action(pane, "pin", 3600, d.driver)
    sub.finish_parent(1, "done", 4000)
    sub.reconcile(24000, {}, d.driver)
    check(d.records[pane] ~= nil, "finished pin survives idle expiry")
    sub.action(pane, "pin", 25000, d.driver)
    expect(d.records[pane], nil, "unpinning after grace closes immediately")
end

print("subagents fixture ok")
