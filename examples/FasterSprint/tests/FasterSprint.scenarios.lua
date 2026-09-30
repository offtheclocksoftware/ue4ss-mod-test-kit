-- Scenarios for examples/FasterSprint/Scripts/main.lua
-- Run (from the kit root):
--   lua harness/run.lua examples/FasterSprint/Scripts/main.lua examples/FasterSprint/tests/FasterSprint.scenarios.lua
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
local W

-- A world with a player character that has a CharacterMovement component (stock Unreal names).
local function build(H, opts)
    opts = opts or {}
    H.config.forbid_off_thread = true     -- the run fails if the mod registers or runs ANY Lua off the game thread
    local move = H.obj("CharacterMovementComponent_" .. H.world_gen, { MaxWalkSpeed = 600 })
    local w = H.player_world({ pawn_fields = { CharacterMovement = (not opts.no_movement) and move or nil } })
    w.move = move
    return w
end

-- The game fires ClientRestart(NewPawn) on the player controller when a save loads or you respawn.
local function restart(H) H.fire_hook(RESTART, W.pc, W.pawn) end

return {
    setup = function(H) W = build(H) end,
    scenarios = {
        {
            name = "load a save: speed x1.5 on the game thread, self-check PASS, no threading API",
            run = function(H)
                H.run(1)
                restart(H)
                H.eq(H.peek(W.move, "MaxWalkSpeed"), 900, "600 x 1.5 = 900")
                H.eq(H.log_count("applied: walk speed 600.0 -> 900.0"), 1, "applied line logged once")
                H.eq(H.log_count("[SELFCHECK] FasterSprint speed_applied PASS"), 1, "self-check PASS")
                H.eq(H.calls.LoopAsync + H.calls.ExecuteInGameThread + H.calls.ExecuteWithDelay, 0, "no LoopAsync / ExecuteInGameThread / ExecuteWithDelay")
                H.eq(H.calls.RegisterKeyBind, 0, "no key binds")
            end,
        },
        {
            name = "restart again on the same character: no stacking",
            run = function(H)
                restart(H); restart(H); restart(H)
                H.eq(H.peek(W.move, "MaxWalkSpeed"), 900, "still 900 after 3 restarts")
                H.eq(H.log_count("[SELFCHECK] FasterSprint no_stack PASS"), 1, "no_stack self-check PASS")
            end,
        },
        {
            name = "world change: new character gets its own x1.5",
            run = function(H)
                restart(H)
                W = H.change_world(function() return build(H) end)
                H.run(0.5)
                restart(H)
                H.eq(H.peek(W.move, "MaxWalkSpeed"), 900, "new world's component set to 900")
            end,
        },
        {
            name = "config: out-of-range multiplier is clamped to 3.0",
            setup = function(H) package.loaded["config"] = { speed_multiplier = 10 } end,
            run = function(H)
                restart(H)
                H.eq(H.peek(W.move, "MaxWalkSpeed"), 1800, "600 x 3.0 (clamped)")
            end,
        },
        {
            name = "game update: CharacterMovement gone -> one disabled line, self-check FAIL, no errors",
            setup = function(H) H.reset(); W = build(H, { no_movement = true }) end,
            run = function(H)
                for _ = 1, 5 do restart(H) end
                H.eq(H.log_count("feature disabled: faster sprint - game update changed"), 1, "one disabled line")
                H.eq(H.log_count("[SELFCHECK] FasterSprint speed_applied FAIL"), 1, "self-check FAIL line")
            end,
        },
        {
            name = "game update: MaxWalkSpeed renamed -> nothing written, disabled once",
            setup = function(H)
                H.reset()
                W = build(H)
                W.move = H.obj("CharacterMovementComponent_X", { WalkSpeedMax = 600 }, { strict = true })
                H.poke(W.pawn, "CharacterMovement", W.move)
            end,
            run = function(H)
                restart(H); restart(H)
                H.eq(H.peek(W.move, "WalkSpeedMax"), 600, "untouched")
                H.eq(H.log_count("feature disabled: faster sprint"), 1, "disabled once")
            end,
            allow_errors = false,
        },
        {
            name = "game update: ClientRestart hook missing -> one clear line, self-check FAIL",
            setup = function(H) H.missing_hooks[RESTART] = true end,
            run = function(H)
                H.run(2)
                H.eq(H.log_count("feature disabled: faster sprint - game update changed " .. RESTART), 1, "disabled line")
                H.eq(H.log_count("[SELFCHECK] FasterSprint speed_applied FAIL"), 1, "self-check FAIL line")
            end,
        },
        {
            name = "quit: restart after QuitGame does nothing; nothing left running",
            run = function(H)
                H.quit("menu")
                restart(H)
                local r = H.quit_report(1.0)
                H.eq(H.peek(W.move, "MaxWalkSpeed"), 600, "not applied after quit")
                H.eq(#r.alive, 0, "no timers or loops")
                H.eq(r.access_after_teardown, 0, "nothing touched after teardown")
            end,
        },
    },
}
