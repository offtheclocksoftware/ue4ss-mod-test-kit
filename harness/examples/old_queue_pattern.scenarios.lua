-- This file is EXPECTED TO FAIL (exit code 1). It proves the off-thread rule catches the old
-- "LoopAsync schedules, ExecuteInGameThread does the work" pattern in examples/old_queue_pattern,
-- and shows where: the report names the mod's own file:line for every forbidden call.
-- Scenario 1 turns forbid_off_thread OFF (the harness default): the mod "works" and passes, which is exactly why the
-- pattern is dangerous: it looks fine offline and crashes some builds in the game.
-- Scenario 2 turns forbid_off_thread ON (the rule for every game): the same mod FAILS.
-- Run:  lua run.lua examples/old_queue_pattern/Scripts/main.lua examples/old_queue_pattern.scenarios.lua
local W
return {
    setup = function(H)
        local ammo = H.obj("AmmoComponent_1", { CurrentAmmo = 30, MaxAmmo = 30 })
        local weapon = H.obj("Rifle_C_1", { AmmoComponent = ammo })
        W = H.player_world({ pawn_fields = { GetEquippedWeapon = function() return weapon end } })
        W.ammo = ammo
    end,
    scenarios = {
        {
            name = "rule off: the old pattern works and passes (this is the trap)",
            run = function(H)
                H.run(3)
                H.poke(W.ammo, "CurrentAmmo", 1)
                H.run(0.3)
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 30, "refill works through the queue")
                H.eq(H.calls.ExecuteInGameThread > 0, true, "it used ExecuteInGameThread")
            end,
        },
        {
            name = "rule on (forbid_off_thread): the same mod fails (expected)",
            setup = function(H) H.config.forbid_off_thread = true end,
            run = function(H) H.run(3) end,
        },
    },
}
