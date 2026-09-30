-- =======================================================================
-- Faster Sprint 1.0.0 - example mod for the UE4SS crash-safe mod kit
-- Target: a made-up Unreal game ("DemoGame"). Class names follow stock Unreal (Character,
-- CharacterMovementComponent.MaxWalkSpeed), so the idea carries over to many games, but always check
-- your own game's reflection dump before relying on a name.
--
-- What it does: your character walks and runs faster (x1.5 by default, Scripts\config.lua).
--
-- How (the crash-safe pattern):
--   * One game-thread hook does all the work: PlayerController:ClientRestart (post), which the game fires
--     on load, respawn and possession changes. No LoopAsync, no ExecuteInGameThread, no timers, no keybinds.
--   * otc_safe.lua: hooks that can't throw, one "feature disabled" line when a game update moves something,
--     typed writes with read-back.
--   * otc_selfcheck.lua: [SELFCHECK] lines in UE4SS.log say PASS/FAIL from what the mod READ BACK.
--   * Nothing is cached between calls except the original speed per movement component (by address),
--     so repeated restarts never stack the multiplier.
-- SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
-- =======================================================================
local ModName = "FasterSprint"
local ModVersion = "1.0.0"

-- Load a helper that ships next to main.lua: require first (UE4SS puts Scripts\ on package.path),
-- then dofile from this file's folder.
local function load_lib(name)
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then return m end
    local src = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
    local dir = (src:gsub("^@", "")):match("^(.*[/\\])") or ""
    ok, m = pcall(dofile, dir .. name .. ".lua")
    if ok and type(m) == "table" then return m end
    return nil
end

local Safe = load_lib("otc_safe")
if not Safe then
    print(string.format("[%s] otc_safe.lua is missing from Scripts - mod disabled. Reinstall the mod.\n", ModName))
    return
end
local S = Safe.new("[" .. ModName .. "]")

-- Self-checks are optional: without otc_selfcheck.lua the mod runs the same, silently.
local SCmod = load_lib("otc_selfcheck")
local SC = (SCmod and SCmod.new(ModName)) or setmetatable({}, { __index = function() return function() return false end end })

local okc, config = pcall(require, "config")
if not okc or type(config) ~= "table" then config = {} end
local MULT = tonumber(config.speed_multiplier) or 1.5
if MULT < 1.0 then MULT = 1.0 end
if MULT > 3.0 then MULT = 3.0 end

local FEATURE = "faster sprint"
local IsQuitting = false
local Applied = {}   -- [movement component address] = { orig = original speed, new = our speed }

SC:expect("speed_applied", "load a save (or respawn)")
SC:expect("no_stack", "die and respawn once, or travel to another area", { optional = true })

local function Apply(pc, pawn)
    if IsQuitting or not S:enabled(FEATURE) then return end
    local okl, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
    if not okl or isLocal ~= true then return end            -- only the local player's own character
    if not Safe.is_valid(pawn) then return end
    local move = S:get(pawn, "CharacterMovement", nil, "CharacterMovement")
    if not Safe.is_valid(move) then
        S:disable_changed(FEATURE, "Character.CharacterMovement (not found on your character)")
        SC:fail_open("the mod switched itself off: CharacterMovement not found")
        return
    end
    local speed = S:get(move, "MaxWalkSpeed", "number", "MaxWalkSpeed")
    if speed == nil then
        S:disable_changed(FEATURE, "CharacterMovementComponent.MaxWalkSpeed (missing or not a number)")
        SC:fail_open("the mod switched itself off: MaxWalkSpeed not readable")
        return
    end
    local addr = Safe.addr(move)
    local rec = addr and Applied[addr]
    if rec and math.abs(speed - rec.new) < 1e-3 then
        -- already ours: a second restart on the same component must not multiply again
        SC:check("no_stack", true, "MaxWalkSpeed still %.1f after another restart (original %.1f)", speed, rec.orig)
        return
    end
    local new = speed * MULT
    if S:set_num(move, "MaxWalkSpeed", new, "MaxWalkSpeed") then
        if addr then Applied[addr] = { orig = speed, new = new } end
        S:log("applied: walk speed %.1f -> %.1f (x%.2f)", speed, new, MULT)
        SC:pass("speed_applied", "MaxWalkSpeed reads %.1f (original %.1f x %.2f)", new, speed, MULT)
    else
        S:disable_changed(FEATURE, "CharacterMovementComponent.MaxWalkSpeed (write did not stick)")
        SC:fail_open("the mod switched itself off: the speed write did not read back")
    end
end

S:safe_hook("/Script/Engine.KismetSystemLibrary:QuitGame", function() IsQuitting = true end, "QuitGame")
if not S:on_restart(Apply, FEATURE) then
    SC:fail_open("the mod switched itself off: PlayerController:ClientRestart hook not found")
end

S:log("v%s loaded: walk/run speed x%.2f, applied on load and respawn (game thread only).", ModVersion, MULT)
