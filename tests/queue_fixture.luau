--!nonstrict
-- Pure fixture for queue.luau, run directly (`luau tests/queue_fixture.luau`): it loads the real module and
-- asserts ordering, stable ids, immutability, validation-before-mutation, id reservation and previews.
-- Invalid argument shapes are intentional runtime boundary cases.
local queue = require("../queue")

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

-- Call as `refused(label, q.op(...))`: an operation that returns (nil, message, nil) and changed nothing.
local function refused(label: string, item: any, err: any, position: any)
    check(item == nil and type(err) == "string" and err ~= "" and position == nil, label .. ": must be refused with a message")
end

local function join(rows: any, field: string?): string
    local out = {}
    for _, row in ipairs(rows) do
        table.insert(out, tostring(row[field or "prompt"]))
    end
    return table.concat(out, ",")
end

local function order(q: any, pane: number): string
    return join(q.list(pane))
end

local function panes_of(q: any): string
    local out = {}
    for _, pane in ipairs(q.panes()) do
        table.insert(out, tostring(pane))
    end
    return table.concat(out, ",")
end

local function frozen(item: any, label: string)
    check(table.isfrozen(item), label .. ": item must be frozen")
    check(not pcall(function() item.prompt = "mutated" end), label .. ": prompt must be read-only")
    check(not pcall(function() item.id = -1 end), label .. ": id must be read-only")
    check(not pcall(function() item.extra = true end), label .. ": no new fields")
end

local function keys_of(row: any): string
    local names = {}
    for key in pairs(row) do
        table.insert(names, key)
    end
    table.sort(names)
    return table.concat(names, ",")
end

-- Constructor: last_id is the last issued id, ids stay exact integers, an unusable seed is refused.
do
    local function now(): number return 1 end
    local draft = { anchor = 1, prompt = "x" }
    expect(assert(queue.new(now).enqueue(1, draft)).id, 1, "fresh queue first id")
    expect(assert(queue.new(now, 0).enqueue(1, draft)).id, 1, "saved last_id 0")
    expect(assert(queue.new(now, 41).enqueue(1, draft)).id, 42, "id after saved last_id")
    for _, bad in { -1, 1.5, 0 / 0, math.huge, -math.huge, 2 ^ 53, 2 ^ 60, "5", true } do
        check(not pcall(queue.new, now, bad), "last_id " .. tostring(bad) .. " must be refused")
    end
    check(pcall(queue.new, now, 2 ^ 53 - 1), "largest exact integer is a valid last_id")

    local exhausted = queue.new(now, 2 ^ 53 - 1)
    local item, err, position = exhausted.enqueue(1, draft)
    refused("exhausted ids", item, err, position)
    check(string.find(err, "exhausted", 1, true) ~= nil and not exhausted.has_any(), "exhaustion leaves the queue empty")

    local last = queue.new(now, 2 ^ 53 - 2)
    expect(assert(last.enqueue(1, draft)).id, 2 ^ 53 - 1, "last representable id")
    refused("id after the last representable one", last.enqueue(1, draft))
    expect(last.count(1), 1, "refused enqueue left the queue unchanged")
end

-- Core: ordering, stable ids, frozen items, listing and lookup.
local clock = 100
local function now(): number
    clock += 5
    return clock
end
local q = queue.new(now)
local function add(pane: number, anchor: any, cid: any, prompt: any, position: any): (any, any, any)
    return q.enqueue(pane, { anchor = anchor, cid = cid, prompt = prompt }, position)
end

local alpha, alpha_err, alpha_pos = add(2, 1, nil, "alpha")
check(alpha and alpha_err == nil and alpha_pos == 1, "enqueue alpha")
local beta, _, beta_pos = add(2, 1, 11, "beta")
local gamma, _, gamma_pos = add(2, 1, nil, "gamma")
expect(beta_pos, 2, "beta position")
expect(gamma_pos, 3, "gamma position")
expect(alpha.id .. "," .. beta.id .. "," .. gamma.id, "1,2,3", "ids are issued in order")
expect(alpha.pane, 2, "alpha pane")
expect(alpha.anchor, 1, "alpha anchor")
expect(alpha.cid, nil, "async item has no caller")
expect(alpha.enqueued_ms, 105, "alpha time")
expect(beta.cid, 11, "beta caller")
expect(beta.enqueued_ms, 110, "beta time")
frozen(alpha, "enqueue")

-- Every refusal leaves the queue untouched and does not consume an id.
refused("empty prompt", add(2, 1, nil, ""))
refused("blank prompt", add(2, 1, nil, "  \n\t "))
refused("missing prompt", add(2, 1, nil, nil))
refused("numeric prompt", add(2, 1, nil, 5))
refused("fractional pane", q.enqueue(1.5, { anchor = 1, prompt = "x" }))
refused("NaN pane", q.enqueue(0 / 0, { anchor = 1, prompt = "x" }))
refused("missing entry", q.enqueue(2, nil))
refused("non-table entry", q.enqueue(2, "text"))
refused("missing anchor", add(2, nil, nil, "x"))
refused("string anchor", add(2, "1", nil, "x"))
refused("fractional caller", add(2, 1, 1.5, "x"))
refused("position 0", add(2, 1, nil, "x", 0))
refused("position past the end", add(2, 1, nil, "x", 5))
refused("fractional position", add(2, 1, nil, "x", 1.5))
refused("string position", add(2, 1, nil, "x", "1"))
expect(order(q, 2), "alpha,beta,gamma", "queue after refused enqueues")

local front, _, front_pos = add(2, 1, nil, "front", 1)
local tail, _, tail_pos = add(2, 1, nil, "tail", 5)
local other, _, other_pos = add(3, 9, 12, "other")
expect(front.id .. "," .. tail.id .. "," .. other.id, "4,5,6", "refusals did not consume ids")
expect(front_pos .. "," .. tail_pos .. "," .. other_pos, "1,5,1", "positional enqueue")
expect(order(q, 2), "front,alpha,beta,gamma,tail", "insert at head and append by position")
expect(other.anchor .. "," .. other.cid .. "," .. other.pane, "9,12,3", "other item fields")

local snaps = q.list(2)
expect(#snaps, 5, "snapshot count")
expect(keys_of(snaps[1]), "anchor,enqueued_ms,id,pane,position,preview,prompt,waiting_caller", "snapshot fields")
expect(snaps[1].id .. snaps[1].pane .. snaps[1].position .. snaps[1].anchor, "4211", "snapshot ids")
expect(snaps[1].enqueued_ms, 120, "snapshot time")
check(snaps[3].waiting_caller == true and snaps[1].waiting_caller == false, "waiting_caller follows the caller id")
check(snaps[3].cid == nil, "the mux client id is not exposed")
check(not table.isfrozen(snaps[1]), "snapshots are fresh tables")
snaps[1].prompt = "hacked"
table.remove(snaps, 1)
expect(order(q, 2), "front,alpha,beta,gamma,tail", "mutating a snapshot cannot change the queue")
expect(#q.list(77), 0, "unknown pane lists nothing")

expect(join(q.list_panes({ 3, 2 })), "other,front,alpha,beta,gamma,tail", "list_panes keeps the order given")
expect(q.list_panes({ 3, 2 })[1].pane, 3, "list_panes snapshots carry their pane")
expect(#q.list_panes({}), 0, "list_panes of nothing")
expect(#q.list_panes({ 99 }), 0, "list_panes of an unknown pane")

local compact = q.compact(2)
expect(#compact, 5, "compact count")
expect(keys_of(compact[1]), "id,position,preview", "compact fields")
expect(compact[2].id .. compact[2].position .. compact[2].preview, "12alpha", "compact row")
expect(#q.compact(77), 0, "unknown pane has no compact rows")
expect(q.count(2), 5, "count")
expect(q.count(77), 0, "count of unknown pane")
expect(panes_of(q), "2,3", "panes are sorted")
check(q.has_any(), "has_any with queued items")

local found_pane, found_pos, found = q.find(beta.id)
check(found_pane == 2 and found_pos == 3 and rawequal(found, beta), "find by id alone")
frozen(found, "find")
local scoped_pane, scoped_pos, scoped = q.find(beta.id, 2)
check(scoped_pane == 2 and scoped_pos == 3 and rawequal(scoped, beta), "find on the right pane")
for label, args in { wrong_pane = { beta.id, 3 }, unknown_id = { 999 }, unknown_pane = { beta.id, 99 } } do
    local a, b, c = q.find(table.unpack(args))
    check(a == nil and b == nil and c == nil, "find " .. label .. " finds nothing")
end

-- Edit keeps id, slot, caller, anchor and time; it replaces the item instead of mutating it.
local edited, edit_err, edit_pos = q.edit(beta.id, "beta2")
check(edited and edit_err == nil and edit_pos == 3, "edit beta")
check(edited.id == beta.id and edited.cid == 11 and edited.anchor == 1 and edited.enqueued_ms == 110, "edit keeps identity")
check(edited.prompt == "beta2" and beta.prompt == "beta" and not rawequal(edited, beta), "edit replaces, never mutates")
check(rawequal(select(3, q.find(beta.id)), edited), "find returns the edited item")
frozen(edited, "edit")
refused("edit on the wrong pane", q.edit(beta.id, "x", 3))
refused("edit with empty prompt", q.edit(beta.id, ""))
refused("edit with blank prompt", q.edit(beta.id, "  "))
refused("edit with missing prompt", q.edit(beta.id, nil))
refused("edit of unknown id", q.edit(999, "x"))
expect(order(q, 2), "front,alpha,beta2,gamma,tail", "refused edits changed nothing")
check(string.find(select(2, q.edit(999, "x")), "not found", 1, true) ~= nil, "unknown edit explains itself")
local beta2, _, beta2_pos = q.edit(beta.id, "beta2", 2)
check(beta2 and beta2_pos == 3 and beta2.prompt == "beta2", "edit constrained to its pane")

-- Move: same-pane slots, appends, cross-pane moves, and refusals before any mutation.
local moved, move_err, move_pos = q.move(gamma.id, 1)
check(rawequal(moved, gamma) and move_err == nil and move_pos == 1, "same-pane move reuses the item")
expect(order(q, 2), "gamma,front,alpha,beta2,tail", "move to head")
local _, noop_err, noop_pos = q.move(gamma.id, 1)
check(noop_err == nil and noop_pos == 1 and order(q, 2) == "gamma,front,alpha,beta2,tail", "moving to the current slot is a no-op")
local _, _, end_pos = q.move(gamma.id, nil, 2)
expect(end_pos, 5, "move to end of own pane")
expect(order(q, 2), "front,alpha,beta2,tail,gamma", "order after move to end")

refused("slot past the end", q.move(front.id, 6))
refused("slot 0", q.move(front.id, 0))
refused("fractional slot", q.move(front.id, 1.5))
refused("no destination", q.move(front.id))
refused("fractional pane", q.move(front.id, 1, 1.5))
refused("unknown id", q.move(999, 1))
refused("wrong source pane", q.move(front.id, 1, nil, 3))
expect(order(q, 2) .. "|" .. order(q, 3), "front,alpha,beta2,tail,gamma|other", "refused moves changed nothing")

local cross, cross_err, cross_pos = q.move(beta2.id, 1, 3)
check(cross and cross_err == nil and cross_pos == 1, "cross-pane move")
check(cross.pane == 3 and cross.id == 2 and cross.cid == 11 and cross.anchor == 1, "cross-pane move keeps id, caller, anchor")
check(cross.enqueued_ms == 110 and cross.prompt == "beta2", "cross-pane move keeps time and prompt")
check(beta2.pane == 2, "the previous snapshot of the item is untouched")
frozen(cross, "cross-pane move")
expect(order(q, 2) .. "|" .. order(q, 3), "front,alpha,tail,gamma|beta2,other", "queues after cross-pane move")
local cross_found_pane, cross_found_pos, cross_found = q.find(2)
check(cross_found_pane == 3 and cross_found_pos == 1 and rawequal(cross_found, cross), "find follows the move")

refused("cross-pane slot past the end", q.move(front.id, 4, 3))
expect(order(q, 2) .. "|" .. order(q, 3), "front,alpha,tail,gamma|beta2,other", "refused cross-pane move changed nothing")
local _, _, append_pos = q.move(front.id, 3, 3)
expect(append_pos, 3, "cross-pane move to the last slot")
expect(order(q, 2) .. "|" .. order(q, 3), "alpha,tail,gamma|beta2,other,front", "queues after append move")

local _, _, fresh_pos = q.move(gamma.id, nil, 7)
expect(fresh_pos, 1, "move into a new pane")
expect(panes_of(q) .. "|" .. order(q, 7), "2,3,7|gamma", "new pane appears")
refused("slot past the end of a one-item queue", q.move(gamma.id, 2, 7))
local _, _, back_pos = q.move(gamma.id, nil, 2)
expect(back_pos, 3, "move back appends")
expect(panes_of(q) .. "|" .. order(q, 2), "2,3|alpha,tail,gamma", "emptied pane is dropped")

-- Reorder: exact permutations only, no maps or side fields, nothing changes on refusal.
check(q.reorder(2, { 3, 1, 5 }) == true, "reorder to a permutation")
expect(order(q, 2), "gamma,alpha,tail", "order after reorder")
local _, reordered_pos, reordered = q.find(3)
check(reordered_pos == 1 and reordered.prompt == "gamma", "reorder keeps ids")
for label, ids in {
    short = { 3, 1 },
    long = { 3, 1, 5, 2 },
    unknown = { 3, 1, 99 },
    duplicate = { 3, 3, 1 },
    other_pane = { 3, 1, 2 },
    string_id = { 3, 1, "x" },
    fractional_id = { 3, 1, 1.5 },
    side_field = { 3, 1, 5, extra = true },
    far_key = { 3, 1, 5, [10] = 7 },
    map = { first = 3, second = 1, third = 5 },
    hole = { [1] = 3, [3] = 5, [4] = 1 },
    scalar = "abc",
} do
    local ok, err = q.reorder(2, ids)
    check(ok == false and type(err) == "string" and err ~= "", "reorder " .. label .. " must be refused")
    expect(order(q, 2), "gamma,alpha,tail", "reorder " .. label .. " changed the queue")
end
local nil_ok, nil_err = q.reorder(2, nil)
check(nil_ok == false and type(nil_err) == "string", "reorder without a list")
check(q.reorder(99, {}) == true, "reorder of an empty pane with an empty list")
check(q.reorder(99, { 1 }) == false, "reorder of an empty pane with ids")
check(q.reorder(99, { note = "x" }) == false, "reorder of an empty pane with a map")

-- Cancel by id, by slot and by pane.
local cancelled, cancel_err = q.cancel_by_id(3)
check(cancelled and cancel_err == nil and cancelled.id == 3 and cancelled.prompt == "gamma", "cancel by id")
frozen(cancelled, "cancel_by_id")
expect(order(q, 2), "alpha,tail", "queue after cancel by id")
local no_item, no_err = q.cancel_by_id(3)
check(no_item == nil and string.find(no_err, "not found", 1, true) ~= nil, "cancel of a removed id")
local wrong_item, wrong_err = q.cancel_by_id(alpha.id, 3)
check(wrong_item == nil and type(wrong_err) == "string" and order(q, 2) == "alpha,tail", "cancel on the wrong pane")

local removed, removed_err = q.cancel_at(2, 1)
check(#removed == 1 and removed_err == nil and removed[1].id == 1 and removed[1].prompt == "alpha", "cancel by slot")
frozen(removed[1], "cancel_at")
expect(order(q, 2), "tail", "queue after cancel by slot")
for label, args in { past_end = { 2, 5 }, zero = { 2, 0 }, fractional = { 2, 1.5 }, empty_pane = { 50, 1 } } do
    local rows, err = q.cancel_at(table.unpack(args))
    check(#rows == 0 and type(err) == "string", "cancel_at " .. label .. " must be refused")
end
check(string.find(select(2, q.cancel_at(50, 1)), "empty", 1, true) ~= nil, "slot on an empty queue says so")
expect(order(q, 2), "tail", "refused cancels changed nothing")

local everything, everything_err = q.cancel_at(3)
check(everything_err == nil and join(everything) == "beta2,other,front", "cancel a whole pane")
check(table.isfrozen(everything[1]) and q.count(3) == 0 and panes_of(q) == "2", "cancelled pane is gone")
local none, none_err = q.cancel_at(3)
check(#none == 0 and none_err == nil, "cancelling an empty pane is not an error")
check(join(q.clear_pane(2)) == "tail" and not q.has_any(), "clear_pane hands over the queue")
check(#q.clear_pane(2) == 0, "clear_pane of an empty pane")

-- Caller disconnects and promotion: drop_cid, pop_next and ids that are never reused.
do
    local q2 = queue.new(now, 99)
    local function add2(pane: number, cid: any, prompt: string): any
        return (q2.enqueue(pane, { anchor = 1, cid = cid, prompt = prompt }))
    end
    local p5a = add2(5, 21, "p5a")
    local p5b = add2(5, nil, "p5b")
    add2(5, 21, "p5c")
    add2(4, 21, "p4a")
    add2(4, 22, "p4b")
    expect(p5a.id, 100, "first id after last_id 99")
    expect(panes_of(q2), "4,5", "panes are sorted whatever the insertion order")

    expect(#q2.drop_cid(999), 0, "drop_cid of an unknown caller")
    expect(#q2.drop_cid(nil), 0, "drop_cid(nil) must not drop async items")
    expect(#q2.drop_cid("21"), 0, "drop_cid of a non-number")
    expect(q2.count(5), 3, "async item survived drop_cid(nil)")

    local dropped = q2.drop_cid(21)
    expect(join(dropped), "p4a,p5a,p5c", "drop_cid removes one caller's tasks in pane and slot order")
    check(table.isfrozen(dropped[1]), "dropped items are frozen")
    expect(order(q2, 5) .. "|" .. order(q2, 4), "p5b|p4b", "other tasks remain")
    expect(join(q2.drop_cid(22)), "p4b", "drop_cid drops a pane's last task")
    expect(panes_of(q2), "5", "pane emptied by drop_cid disappears")

    local popped = q2.pop_next(5)
    check(rawequal(popped, p5b) and popped.id == 101, "pop_next returns the head item")
    frozen(popped, "pop_next")
    check(q2.pop_next(5) == nil and q2.pop_next(4) == nil and not q2.has_any(), "pop_next on empty panes")
    expect(panes_of(q2), "", "no panes left")

    local fresh = add2(5, nil, "fresh")
    add2(5, nil, "second")
    expect(fresh.id, 105, "ids are never reused")
    expect(q2.pop_next(5).prompt .. "," .. q2.pop_next(5).prompt, "fresh,second", "pop_next is first in, first out")
end

-- Durable id reservation runs after validation and before anything is exposed or changed.
do
    local requested, counts_during, found_during = {}, {}, {}
    local mode = "accept"
    local q3
    q3 = queue.new(now, 39, function(id: number): (boolean, string?)
        table.insert(requested, id)
        table.insert(counts_during, q3.count(8))
        table.insert(found_during, q3.find(id) ~= nil)
        if mode == "refuse" then
            return false, "store full"
        elseif mode == "refuse_silently" then
            return false, nil
        elseif mode == "throw" then
            error("store exploded")
        end
        return true, nil
    end)
    local function add3(prompt: any, position: any): (any, any, any)
        return q3.enqueue(8, { anchor = 1, prompt = prompt }, position)
    end

    local one, _, one_pos = add3("one")
    check(one.id == 40 and one_pos == 1 and #requested == 1 and requested[1] == 40, "port sees the id")
    check(counts_during[1] == 0 and found_during[1] == false, "port runs before the item is exposed")

    refused("invalid prompt", add3(""))
    refused("invalid position", add3("x", 9))
    refused("invalid entry", q3.enqueue(8, { anchor = "a", prompt = "x" }))
    expect(#requested, 1, "port is not called for invalid requests")

    mode = "refuse"
    local item, err, position = add3("two")
    check(item == nil and err == "store full" and position == nil, "refusal returns its reason")
    check(q3.count(8) == 1 and #requested == 2 and requested[2] == 41, "refusal leaves the queue unchanged")
    mode = "refuse_silently"
    refused("refusal without reason", add3("two"))
    expect(requested[3], 41, "refused id is offered again")
    mode = "throw"
    local ok, message = pcall(add3, "two")
    check(not ok and string.find(tostring(message), "store exploded", 1, true) ~= nil, "port failure propagates")
    check(q3.count(8) == 1 and requested[4] == 41, "failing port leaves the queue unchanged")

    mode = "accept"
    local two, _, two_pos = add3("two")
    check(two.id == 41 and two_pos == 2 and requested[5] == 41, "refused ids were not consumed")
    check(counts_during[5] == 1 and found_during[5] == false, "port still sees the pre-enqueue queue")

    q3.edit(40, "uno")
    q3.move(40, 2)
    q3.cancel_by_id(41)
    expect(order(q3, 8), "uno", "other operations proceed")
    check(q3.pop_next(8).prompt == "uno" and not q3.has_any(), "pop_next drains")
    expect(#requested, 5, "only enqueue reserves ids")
end

-- Status previews: first 120 bytes, never a split UTF-8 character, newlines untouched.
do
    local q4 = queue.new(now)
    local pane = 0
    local function preview_of(prompt: string): string
        pane += 1
        q4.enqueue(pane, { anchor = 1, prompt = prompt })
        local row = q4.compact(pane)[1]
        check(row.position == 1, "preview row position")
        local text = row.preview
        check(utf8.len(text) ~= nil, "preview is valid UTF-8")
        check(q4.list(pane)[1].prompt == prompt, "the queued prompt keeps its full text")
        return text
    end
    local e_acute = utf8.char(0xE9)
    local grin = utf8.char(0x1F600)

    expect(preview_of("short"), "short", "short prompt")
    expect(preview_of(string.rep("x", 120)), string.rep("x", 120), "exactly 120 bytes")
    expect(#preview_of(string.rep("x", 121)), 120, "121 ASCII bytes")
    expect(preview_of("x\ny"), "x\ny", "newlines are kept")
    expect(#preview_of(string.rep(e_acute, 100)), 120, "two-byte characters on the boundary")
    local split_two = preview_of("a" .. string.rep(e_acute, 100))
    check(#split_two == 119 and utf8.len(split_two) == 60, "a two-byte character split by the cut is dropped")
    local split_four = preview_of("ab" .. string.rep(grin, 50))
    check(#split_four == 118 and utf8.len(split_four) == 31, "a four-byte character split by the cut is dropped")
    expect(preview_of(string.rep("\128", 200)), "", "stray continuation bytes never yield a split character")
end

do
    local pending = queue.new(now)
    local item = assert(pending.enqueue(2, { anchor = 1, prompt = "original", thinking = "high" }))
    expect(pending.list(2)[1].thinking, "high", "thinking on queue snapshot")
    assert(pending.edit(item.id, "revised"))
    assert(pending.move(item.id, 1, 3))
    expect(pending.list_panes({ 2, 3 })[1].thinking, "high", "thinking follows edited and moved task")
    local next_item = assert(pending.pop_next(3))
    expect(next_item.thinking, "high", "thinking at dispatch")
    expect(next_item.prompt, "revised", "edited prompt at dispatch")
end
