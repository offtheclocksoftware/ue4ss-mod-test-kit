-- Unit test for otc_keys.lua against the offline fake UE4SS (no game):  lua lib/tests/test_otc_keys.lua
-- SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local H = dofile(here .. "/../../harness/fake_ue4ss.lua")
local Safe = dofile(here .. "/../otc_safe.lua")
local Keys = dofile(here .. "/../otc_keys.lua")

local fails, checks = 0, 0
local function eq(a, b, msg)
    checks = checks + 1
    if a ~= b then fails = fails + 1; io.write(string.format("FAIL %s (expected %s, got %s)\n", msg, tostring(b), tostring(a))) end
end

local FRAME = "/Script/ExampleGame.ExampleHUD:UpdateHUD"
local W

-- fresh world with an in-game HUD that the game "updates" every frame on the game thread
local function boot()
    H.reset()
    H.config.forbid_off_thread = true
    W = H.player_world()
    W.hud = H.obj("ExampleHUD_1", { PlayerOwner = W.pc }, { class = H.class("ExampleHUD", "Actor") })
    H.every_frame_hook(FRAME, function() return W.hud end)
    return Safe.new("[Test]")
end
local function press(name, hold)
    H.key_down(name, true); H.run(hold or 0.1); H.key_down(name, false); H.run(0.1)
end

-- key name mapping
eq(Keys.unreal_name("NUM_FOUR"), "NumPadFour", "UE4SS name maps to the Unreal FKey name")
eq(Keys.unreal_name("numpadfour"), "NumPadFour", "Unreal names work, any case")
eq(Keys.unreal_name("F11"), "F11", "function key")
eq(Keys.unreal_name("NONE"), nil, "NONE = no key")
eq(Keys.unreal_name("BANANA"), nil, "unknown name = no key")

-- one press = one action; holding does not repeat; nothing runs off the game thread
do
    local S = boot()
    local n = 0
    local K = Keys.new(S, { { name = "NUM_ONE", what = "test", on_press = function() n = n + 1 end } })
    eq(K:start(FRAME), true, "per-frame hook registered")
    H.run(0.1)                                   -- first read arms the key
    press("NumPadOne")
    eq(n, 1, "one press fires once")
    press("NumPadOne", 2.0)
    eq(n, 2, "a 2 s hold fires once more, not once per frame")
    eq(H.calls.RegisterKeyBind + H.calls.LoopAsync + H.calls.ExecuteInGameThread, 0, "no RegisterKeyBind / LoopAsync / ExecuteInGameThread")
    eq(H.key_reads.game ~= nil and H.key_reads.game > 0, true, "keys read on the game thread")
    eq(H.key_reads.input, nil, "never read on the input thread")
    eq(#H.violations, 0, "no forbidden threading use (forbid_off_thread on)")
    eq(#H.errors, 0, "no Lua errors")
end

-- a key already held when polling starts does not fire
do
    local S = boot()
    local n = 0
    local K = Keys.new(S, { { name = "NUM_ONE", what = "test", on_press = function() n = n + 1 end } })
    K:start(FRAME)
    H.key_down("NumPadOne", true)
    H.run(1.0)
    eq(n, 0, "held at startup: no fire")
    H.key_down("NumPadOne", false); H.run(0.1)
    press("NumPadOne")
    eq(n, 1, "a real press afterwards fires")
end

-- no key configured = no hook at all
do
    local S = boot()
    local K = Keys.new(S, { { name = "NONE", what = "test", on_press = function() end } })
    eq(K:start(FRAME), false, "no key: start() does nothing")
    eq(H.calls.RegisterHook, 0, "no hook registered")
    eq(K:describe(), "no key", "describe")
end

-- unknown key name: one warning, no hook
do
    local S = boot()
    local K = Keys.new(S, { { name = "BANANA", what = "test", on_press = function() end } })
    eq(K:start(FRAME), false, "unknown key: no hook")
    eq(H.log_count("unknown key name 'BANANA'"), 1, "one clear line")
end

-- start() without a hook path fails closed with one line
do
    local S = boot()
    local K = Keys.new(S, { { name = "F5", what = "test", on_press = function() end } })
    eq(K:start(), false, "no path: not started")
    eq(H.log_count("no per-frame hook path"), 1, "one clear line")
end

-- renamed per-frame function: fails closed, one line, no errors
do
    local S = boot()
    H.missing_hooks[FRAME] = true
    local K = Keys.new(S, { { name = "F5", what = "test", on_press = function() end } })
    eq(K:start(FRAME), false, "missing hook: not started")
    H.run(0.5)
    eq(#H.errors, 0, "no Lua errors")
end

-- IsInputKeyDown failing every frame: hotkeys switch themselves off with one line
do
    local S = boot()
    local K = Keys.new(S, { { name = "F5", what = "test", on_press = function() end } })
    K:start(FRAME)
    H.poke(W.pc, "IsInputKeyDown", function() error("renamed") end)
    H.run(2.0)
    eq(H.log_count("hotkeys off: PlayerController:IsInputKeyDown failed"), 1, "one 'hotkeys off' line")
end

-- stop(): nothing fires after quit
do
    local S = boot()
    local n = 0
    local K = Keys.new(S, { { name = "NUM_ONE", what = "test", on_press = function() n = n + 1 end } })
    K:start(FRAME)
    H.run(0.1)
    K:stop()
    press("NumPadOne")
    eq(n, 0, "no fire after stop()")
end

-- a failing on_press is contained and logged once
do
    local S = boot()
    local K = Keys.new(S, { { name = "NUM_ONE", what = "test", on_press = function() error("boom") end } })
    K:start(FRAME)
    H.run(0.1)
    press("NumPadOne"); press("NumPadOne")
    eq(H.log_count("key action failed"), 1, "failure logged once")
    eq(#H.errors, 0, "error never escapes")
end

if fails == 0 then io.write(string.format("RESULT: PASS (otc_keys, %d checks)\n", checks)) os.exit(0) end
io.write(string.format("RESULT: FAIL (%d of %d checks)\n", fails, checks))
os.exit(1)
