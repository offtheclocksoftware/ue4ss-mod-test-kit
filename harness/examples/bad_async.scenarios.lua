-- This scenario is EXPECTED TO FAIL. It proves the harness catches background-thread UObject access
-- and the "guard declared after the function" bug in examples/bad_async/Scripts/main.lua.
-- Run:  lua run.lua examples/bad_async/Scripts/main.lua examples/bad_async.scenarios.lua   (exit code 1)
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
            name = "normal play (bad mod)",
            run = function(H)
                H.poke(W.ammo, "CurrentAmmo", 1)
                H.run(1)
                H.eq(H.peek(W.ammo, "CurrentAmmo"), 30, "refill 'works' - but from the wrong thread")
            end,
        },
        {
            name = "quit (bad mod)",
            run = function(H)
                H.run(0.5)
                H.quit("menu")
                local r = H.quit_report(1.0)
                H.eq(#r.alive, 0, "background loop stopped after quit")
            end,
        },
    },
}
