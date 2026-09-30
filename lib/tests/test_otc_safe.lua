-- Unit test for otc_safe.lua against the offline fake UE4SS (no game):  lua lib/tests/test_otc_safe.lua
-- SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local H = dofile(here .. "/../../harness/fake_ue4ss.lua")
local Safe = dofile(here .. "/../otc_safe.lua")

local fails, checks = 0, 0
local function eq(a, b, msg)
    checks = checks + 1
    if a ~= b then fails = fails + 1; io.write(string.format("FAIL %s (expected %s, got %s)\n", msg, tostring(b), tostring(a))) end
end
local function fresh() H.reset(); return Safe.new("[Test]") end

-- safe_find: an invalid wrapper is "not found", a live object is returned
do
    local S = fresh()
    eq(S:safe_find("PlayerController"), nil, "safe_find: nothing there -> nil (not the invalid wrapper)")
    local w = H.player_world()
    eq(S:safe_find("PlayerController"), w.pc, "safe_find: live object returned")
    eq(Safe.is_valid(H.invalid), false, "is_valid(invalid wrapper) is false")
    eq(Safe.is_valid(nil), false, "is_valid(nil) is false")
end

-- safe_hook: a vanished UFunction -> one clear line, feature disabled, no error
do
    local S = fresh()
    H.missing_hooks["/Script/Game.Thing:Gone"] = true
    eq(S:safe_hook("/Script/Game.Thing:Gone", function() end, "gone"), nil, "missing hook returns nil")
    eq(S:enabled("gone"), false, "feature disabled")
    eq(H.log_count("feature disabled: gone - game update changed"), 1, "one disabled line")
    eq(#H.errors, 0, "no Lua errors")
end

-- safe_hook: a callback that keeps failing goes idle after max_hook_errors
do
    local S = fresh()
    local calls = 0
    S:safe_hook("/Script/Game.Thing:Tick", function() calls = calls + 1; error("boom") end, "tick")
    for _ = 1, 20 do H.fire_hook("/Script/Game.Thing:Tick", H.invalid) end
    eq(calls, 5, "callback stops being called after 5 errors")
    eq(S:enabled("tick"), false, "feature disabled after repeated errors")
    eq(H.log_count("hook tick (pre) error"), 1, "error logged once")
    eq(#H.errors, 0, "errors never escape to UE4SS")
end

-- run_gt: runs directly inside a helper hook; refuses (and disables) anywhere else; never queues by default
do
    local S = fresh()
    local ran = 0
    eq(S:run_gt("outside", function() ran = ran + 1 end), false, "run_gt outside a hook refuses")
    eq(ran, 0, "nothing ran outside a hook")
    eq(S:enabled("outside"), false, "feature disabled with one line")
    S:safe_hook("/Script/Game.Thing:Tick", function() S:run_gt("inside", function() ran = ran + 1 end) end, "tick")
    H.fire_hook("/Script/Game.Thing:Tick", H.invalid)
    eq(ran, 1, "run_gt inside a hook runs synchronously")
    eq(H.calls.ExecuteInGameThread, 0, "no ExecuteInGameThread")
end

-- after / loop / safe_key: off unless the mod opts in; no threading API is ever called
do
    local S = fresh()
    H.config.forbid_off_thread = true
    eq(S:after(100, "later", function() end), false, "after() refused without opt-in")
    local st = S:loop(100, "looping", function() end)
    eq(st.stop, true, "loop() refused without opt-in")
    eq(S:safe_key(Key.F5, nil, function() end, "hotkey"), false, "safe_key() refused without opt-in")
    eq(H.calls.LoopAsync + H.calls.ExecuteWithDelay + H.calls.ExecuteInGameThread + H.calls.RegisterKeyBind, 0, "no LoopAsync / ExecuteWithDelay / ExecuteInGameThread / RegisterKeyBind calls")
    eq(#H.violations, 0, "nothing forbidden registered or run off the game thread")
end

-- the opt-in queue helpers are reported by the harness under forbid_off_thread, at the caller's line (not inside otc_safe)
do
    H.reset()
    H.config.forbid_off_thread = true
    local S = Safe.new("[Test]", { allow_game_thread_queue = true })
    S:after(100, "later", function() end)
    local hit = false
    for _, v in ipairs(H.violations) do
        if v.kind == "off-thread-api" and v.where:find("test_otc_safe", 1, true) then hit = true end
    end
    eq(hit, true, "opt-in S:after is flagged with the mod's own file:line")
end

-- set_num: typed write with read-back; refuses to write a property that is missing or not a number
do
    local S = fresh()
    local o = H.obj("Stats_1", { Speed = 600, Name = "x" })
    eq(S:set_num(o, "Speed", 900), true, "numeric write verified")
    eq(H.peek(o, "Speed"), 900, "value written")
    eq(S:set_num(o, "Name", 5), false, "non-number property refused")
    eq(H.peek(o, "Name"), "x", "non-number property untouched")
    eq(S:set_num(o, "Missing", 5), false, "missing property refused")
end

-- on_restart: fn(pc, pawn) on the game thread with unwrapped, validated objects
do
    local S = fresh()
    local w = H.player_world()
    local got_pc, got_pawn
    eq(S:on_restart(function(pc, pawn) got_pc, got_pawn = pc, pawn end, "restart"), true, "ClientRestart hook registered")
    H.fire_hook("/Script/Engine.PlayerController:ClientRestart", w.pc, w.pawn)
    eq(got_pc, w.pc, "pc unwrapped")
    eq(got_pawn, w.pawn, "pawn unwrapped")
end

-- arrays: 0-based helpers over UE4SS's 1-based TArray, no silent fallback
do
    local arr = H.array({ "a", "b" })
    eq(Safe.arr_num(arr), 2, "arr_num")
    eq(Safe.arr_get(arr, 0), "a", "arr_get index 0 = first element")
    eq(Safe.arr_get(arr, 2), nil, "out of range -> nil")
end

-- debounce (wall clock)
do
    local S = fresh()
    eq(S:debounce("k", 1), true, "first accept")
    eq(S:debounce("k", 1), false, "second call within 1 s refused")
    H.run(1.1)
    eq(S:debounce("k", 1), true, "accepted again after 1 s")
end

if fails == 0 then io.write(string.format("RESULT: PASS (otc_safe, %d checks)\n", checks)) os.exit(0) end
io.write(string.format("RESULT: FAIL (%d of %d checks)\n", fails, checks))
os.exit(1)
