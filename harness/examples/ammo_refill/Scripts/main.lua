-- Example mod: keeps the equipped weapon's magazine full.
-- Crash-safe, hook-driven pattern (the only pattern this kit endorses):
--   * ALL work happens inside a hook on a UFunction the game itself calls every frame on its game thread
--     (here the player character's tick function). No LoopAsync, no ExecuteInGameThread, no timers, no key binds.
--   * The hook body is cheap: a time check first, the real work at most 10 times a second.
--   * The object to work on is the hook's own `self` (the character the game is ticking): no FindFirstOf per frame.
--   * QuitGame stops everything; a world change is detected by the world's address and waited out.
--   * Nothing is cached across callbacks; every object is IsValid()-checked right before use.
-- Class and function names belong to a made-up game. Take yours from your game's reflection dump, and confirm
-- with a log line (as below) that the hook really fires before relying on it.
local ModName = "AmmoRefill"
local TICK_HOOK = "/Script/ExampleGame.ExampleCharacter:TickWeaponState"
local WORK_SECONDS = 0.1

-- Guard state is declared FIRST, before any function that reads it.
local IsQuitting = false
local Disabled = false
local HookFired = false
local NextWork = 0
local LastWorldAddr, SettleUntil = nil, 0
local Warned = {}
local NextSearch, Backoff = 0, 1.0
local LastRefillLog = -100

local function log(fmt, ...) print(string.format("[%s] " .. fmt, ModName, ...)) end
local function warn_once(key, fmt, ...) if not Warned[key] then Warned[key] = true; log(fmt, ...) end end
local function valid(o) local ok, r = pcall(function() return o ~= nil and o:IsValid() end) return ok and r end
-- Hook parameters (including `self`) are wrapped: :get() gives the object.
local function unwrap(p) local v = p; pcall(function() if p and p.get then v = p:get() end end) return v end
local function going_away(a)
    if not valid(a) then return true end
    local ok, dying = pcall(function() return a.bActorIsBeingDestroyed == true end)
    return (not ok) or dying
end

-- The character the game is ticking, or nil while the world is changing / the character is going away.
local function GetPawn(self, t)
    local pawn = unwrap(self)
    if going_away(pawn) then return nil end
    local okw, world = pcall(function() return pawn:GetWorld() end)
    if not okw or not valid(world) then return nil end
    local addr = world:GetAddress()
    if addr ~= LastWorldAddr then                  -- world changed: let it settle
        if LastWorldAddr then log("World changed - waiting 2 s.") end
        LastWorldAddr, SettleUntil = addr, t + 2.0
        NextSearch, Backoff = 0, 1.0
        return nil
    end
    if t < SettleUntil then return nil end
    return pawn
end

local function Maintain(self, t)
    local pawn = GetPawn(self, t)
    if not pawn then return end
    if t < NextSearch then return end
    local okw, weapon = pcall(function() return pawn:GetEquippedWeapon() end)
    if not okw or not valid(weapon) then return end
    local oka, ammo = pcall(function() return weapon.AmmoComponent end)
    if not oka or not valid(ammo) then
        NextSearch, Backoff = t + Backoff, math.min(Backoff * 2, 10.0)   -- back off, do not spin
        warn_once("noammo", "WARNING: feature disabled due to game update (no ammo component on %s). Retrying with back-off.", weapon:GetFName():ToString())
        return
    end
    Backoff = 1.0
    local cur, max = ammo.CurrentAmmo, ammo.MaxAmmo
    if type(cur) ~= "number" or type(max) ~= "number" then return end
    if cur < max then
        ammo.CurrentAmmo = max
        if t - LastRefillLog >= 3.0 then LastRefillLog = t; log("Refilled ammo to %d (was %d)", max, cur) end
    end
end

-- Runs on the game thread: the game calls TickWeaponState itself, every frame.
local function OnTick(self)
    if IsQuitting or Disabled then return end
    if not HookFired then HookFired = true; log("Tick hook is firing (game thread).") end
    local t = os.clock()
    if t < NextWork then return end
    NextWork = t + WORK_SECONDS
    local ok, err = pcall(Maintain, self, t)
    if not ok then warn_once("err" .. tostring(err), "Pass error (skipped): %s", tostring(err)) end
end

local okq = pcall(RegisterHook, "/Script/Engine.KismetSystemLibrary:QuitGame", function()
    if not IsQuitting then IsQuitting = true; log("QuitGame detected - stopping.") end
end)
if not okq then log("QuitGame hook not available (continuing).") end

local okt, err = pcall(RegisterHook, TICK_HOOK, function(self) OnTick(self) end)
if not okt then
    Disabled = true
    log("WARNING: feature disabled due to game update (tick hook not found: %s).", tostring(err))
end
log("Loaded.")
