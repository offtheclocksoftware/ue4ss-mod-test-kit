-- This file is EXPECTED TO FAIL (exit code 1). It proves the off-thread rule catches RegisterKeyBind and
-- ExecuteInGameThread in examples/old_keybind_pattern, with the mod's own file:line.
-- Scenario 1 (rule off, the harness default): the mod works and passes. Scenario 2 (forbid_off_thread on): it FAILS.
-- Run:  lua run.lua examples/old_keybind_pattern/Scripts/main.lua examples/old_keybind_pattern.scenarios.lua
local W
return {
    setup = function(H)
        local wallet = H.obj("Wallet_1", { Balance = 0,
            AddMoney = function(self, n) H.poke(self, "Balance", H.peek(self, "Balance") + n) end }, { strict = true })
        W = H.player_world({ pawn_fields = { Wallet = wallet } })
        W.wallet = wallet
    end,
    scenarios = {
        {
            name = "rule off: the old pattern works and passes (this is the trap)",
            run = function(H)
                H.eq(H.press(Key.NUM_ONE), 1, "Numpad 1 is bound")
                H.run(0.1)
                H.eq(H.peek(W.wallet, "Balance"), 1000, "+1000")
            end,
        },
        {
            name = "rule on (forbid_off_thread): the same mod fails (expected)",
            setup = function(H) H.config.forbid_off_thread = true end,
            run = function(H) H.press(Key.NUM_ONE); H.run(0.1) end,
        },
    },
}
