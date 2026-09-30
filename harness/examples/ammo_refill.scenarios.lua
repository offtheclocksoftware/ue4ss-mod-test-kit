-- Scenarios for examples/ammo_refill/Scripts/main.lua
-- Run:  lua run.lua examples/ammo_refill/Scripts/main.lua examples/ammo_refill.scenarios.lua
-- Runs with H.config.forbid_off_thread = true: the run fails if the mod registers or runs ANY Lua off the game
-- thread (RegisterKeyBind, LoopAsync, ExecuteInGameThread, ExecuteWithDelay, ...). That is the rule for every game.
local TICK = "/Script/ExampleGame.ExampleCharacter:TickWeaponState"

-- Build a fake world with a player holding a weapon that has an ammo component.
local function build(H, opts)
    opts = opts or {}
    local ammo = H.obj("AmmoComponent_" .. H.world_gen, { CurrentAmmo = 30, MaxAmmo = 30 })
    local weapon = H.obj("Rifle_C_" .. H.world_gen, { AmmoComponent = (not opts.no_ammo) and ammo or nil })
    local w = H.player_world({ pawn_fields = { GetEquippedWeapon = function() return weapon end } })
    w.ammo, w.weapon = ammo, weapon
    return w
end

local W  -- current world for the scenario

-- Start a scenario: forbid off-thread Lua, build the world, and let the game tick the character every frame
-- on the game thread (only while a player exists). Pass nothing for "main menu, no player".
local function boot(H, opts)
    H.config.forbid_off_thread = true
    W = opts and build(H, opts) or nil
    H.every_frame_hook(TICK, function() return W and W.pawn end)
end

return {
    setup = function(H) boot(H, {}) end,
    scenarios = {
        {
            name = "normal play: refills inside the game-thread tick hook, no threading API",
            run = function(H)
                H.run(3)                                   -- 2 s settle after the first world
                H.eq(H.log_count("Tick hook is firing (game thread)."), 1, "hook-fired line once")
                H.poke(W.ammo, "CurrentAmmo", 3)
                H.run(0.2)
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 30, "magazine refilled")
                H.eq(H.async_violations(), 0, "zero UObject touches from a background thread")
                H.eq(H.calls.LoopAsync + H.calls.ExecuteInGameThread + H.calls.ExecuteWithDelay + H.calls.RegisterKeyBind, 0, "no threading API called")
                H.eq(H.calls.FindFirstOf, 0, "works on the hook's own object, no per-frame search")
            end,
        },
        {
            name = "cheap tick: work runs ~10x per second, not every frame",
            run = function(H)
                H.run(3)
                local before = H.accesses["Rifle_C_1.AmmoComponent"]
                H.run(10)                                  -- 400 frames
                local n = H.accesses["Rifle_C_1.AmmoComponent"] - before
                H.check(n >= 80 and n <= 110, "about 100 work passes in 10 s, not 400 (" .. n .. ")")
            end,
        },
        {
            name = "log throttling: constant firing for 10 s logs a few lines, not hundreds",
            run = function(H)
                H.run(3)
                H.on_frame(function() H.poke(W.ammo, "CurrentAmmo", 10) end)  -- the game spends ammo every frame
                H.run(10)
                local n = H.log_count("Refilled ammo")
                H.check(n >= 2 and n <= 5, "Refilled lines throttled to ~1 per 3 s (" .. n .. ")")
            end,
        },
        {
            name = "world change: old objects die, mod waits, then works on the new world",
            run = function(H)
                H.run(3)
                local old = W.ammo
                W = H.change_world(function() return build(H) end)
                H.run(0.5)
                H.eq(H.log_count("World changed - waiting 2 s."), 1, "world change logged")
                H.poke(W.ammo, "CurrentAmmo", 0)
                H.run(0.5)
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 0, "no writes during settle")
                H.run(3)
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 30, "resumes on the new world")
                H.check(not H.is_alive(old), "old ammo object was invalidated by the world change")
            end,
        },
        {
            name = "missing object: weapon without ammo component -> fail closed, warn once, back off",
            setup = function(H) H.reset(); boot(H, { no_ammo = true }) end,
            run = function(H)
                H.run(30)
                H.eq(H.log_count("feature disabled due to game update"), 1, "warned exactly once")
                local searches = H.accesses["Rifle_C_1.AmmoComponent"]      -- counts every read/write of "Object.Member"
                H.check(searches <= 10, "backs off instead of searching every pass (" .. searches .. " searches in 30 s; no back-off would be ~280)")
            end,
        },
        {
            name = "game update renamed the tick function: one clear line, mod idles, no errors",
            setup = function(H) H.missing_hooks[TICK] = true end,
            run = function(H)
                H.run(5)
                H.eq(H.log_count("feature disabled due to game update (tick hook not found"), 1, "disabled line logged once")
                H.eq(H.accesses["AmmoComponent_1.CurrentAmmo"], 0, "nothing touched")
            end,
        },
        {
            name = "main menu: no player, the tick never fires -> nothing happens, no errors",
            setup = function(H) H.reset(); boot(H) end,
            run = function(H)
                H.run(10)
                H.eq(H.log_count("Tick hook is firing"), 0, "no tick without a player")
                H.eq(H.calls.FindFirstOf, 0, "no searches while nothing is ticking")
            end,
        },
        {
            name = "quit: QuitGame stops all work, nothing left running, nothing touched after teardown",
            run = function(H)
                H.run(3)
                H.quit("menu")
                H.poke(W.ammo, "CurrentAmmo", 0)
                local r = H.quit_report(1.0)
                H.eq(H.log_count("QuitGame detected - stopping."), 1, "quit detected")
                H.eq(#r.alive, 0, "no loops or timers alive after quit")
                H.eq(r.access_after_teardown, 0, "no UObject access after teardown")
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 0, "no write after quit")
            end,
        },
    },
}
