-- OLD PATTERN - kept to show what the threading-API check flags. Do not copy; see examples/ammo_refill.
-- A LoopAsync background loop that only schedules, with all UObject work queued through ExecuteInGameThread.
-- It looks careful and passes the background-thread check, but on some UE4SS builds the ExecuteInGameThread
-- queue is drained from the ProcessEvent hook on whatever thread fires it, and mods built this way have
-- crashed games (including on quit). The hook-driven version in examples/ammo_refill avoids the queue entirely.
local ModName = "AmmoRefill"

-- Guard state is declared FIRST, before any function that reads it.
local IsQuitting = false
local PassQueued = false
local PassesRun = 0
local StartTime = os.clock()

local CachedPC, NextPCFind = nil, 0
local LastWorldAddr, SettleUntil = nil, 0
local Warned = {}
local NextSearch, Backoff = 0, 1.0
local LastRefillLog = -100

local function log(fmt, ...) print(string.format("[%s] " .. fmt, ModName, ...)) end
local function warn_once(key, fmt, ...) if not Warned[key] then Warned[key] = true; log(fmt, ...) end end
local function valid(o) local ok, r = pcall(function() return o ~= nil and o:IsValid() end) return ok and r end
local function going_away(a)
    if not valid(a) then return true end
    local ok, dying = pcall(function() return a.bActorIsBeingDestroyed == true end)
    return (not ok) or dying
end

local function GetContext(t)
    if going_away(CachedPC) then
        CachedPC = nil
        if t < NextPCFind then return nil end
        NextPCFind = t + 1.0                          -- search at most once per second
        local ok, pc = pcall(FindFirstOf, "PlayerController")
        if not ok or not valid(pc) then return nil end
        CachedPC = pc
    end
    local ok, world = pcall(function() return CachedPC:GetWorld() end)
    if not ok or not valid(world) then return nil end
    local okgm, gm = pcall(function() return world.AuthorityGameMode end)
    if not okgm or going_away(gm) then return nil end
    local addr = world:GetAddress()
    if addr ~= LastWorldAddr then                  -- world changed: drop cached objects, let it settle
        if LastWorldAddr then log("World changed - waiting 2 s.") end
        LastWorldAddr, SettleUntil = addr, t + 2.0
        NextSearch, Backoff = 0, 1.0
        return nil
    end
    if t < SettleUntil then return nil end
    local okp, pawn = pcall(function() return CachedPC.Pawn end)
    if not okp or going_away(pawn) then return nil end
    return pawn
end

local function Maintain()
    if IsQuitting then return end
    local t = os.clock()
    local pawn = GetContext(t)
    if not pawn then return end
    if t < NextSearch then return end
    local okw, weapon = pcall(function() return pawn:GetEquippedWeapon() end)
    if not okw or not valid(weapon) then return end
    local oka, ammo = pcall(function() return weapon.AmmoComponent end)
    if not oka or not valid(ammo) then
        NextSearch, Backoff = t + Backoff, math.min(Backoff * 2, 10.0)   -- back off, don't spin
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

local function GameThreadPass()
    PassesRun = PassesRun + 1
    if PassesRun == 1 then log("Game-thread passes are running.") end
    if not IsQuitting then
        local ok, err = pcall(Maintain)
        if not ok then warn_once("err" .. tostring(err), "Pass error (skipped): %s", tostring(err)) end
    end
    PassQueued = false
end

local ok = pcall(RegisterHook, "/Script/Engine.KismetSystemLibrary:QuitGame", function()
    if not IsQuitting then IsQuitting = true; log("QuitGame detected - stopping.") end
end)
if not ok then log("QuitGame hook not available (continuing).") end

LoopAsync(100, function()
    -- background thread: NO UObject access here, only scheduling
    if IsQuitting then log("Watchdog stopped."); return true end
    if PassQueued then
        if PassesRun == 0 and os.clock() - StartTime >= 20 then
            warn_once("noexec", "WARNING: feature disabled - no game-thread pass ran in 20 s (UE4SS needs HookUObjectProcessEvent = 1 for ExecuteInGameThread).")
        end
        return false
    end
    PassQueued = true
    local sched = pcall(ExecuteInGameThread, GameThreadPass)
    if not sched then PassQueued = false end
    return false
end)
log("Loaded.")
