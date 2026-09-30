-- Scenarios for examples/keybind_money/Scripts/main.lua
-- Run:  lua run.lua examples/keybind_money/Scripts/main.lua examples/keybind_money.scenarios.lua
-- Runs with H.config.forbid_off_thread = true: the run fails if the mod registers or runs ANY Lua off the game
-- thread (RegisterKeyBind, LoopAsync, ExecuteInGameThread, ...). Keys are read with IsInputKeyDown on the game thread.
local FRAME = "/Script/ExampleGame.ExampleHUD:UpdateHUD"
local KEY = "NumPadOne"
local W

local function build(H, opts)
    opts = opts or {}
    local wallet = H.obj("Wallet_" .. H.world_gen, { Balance = 0,
        AddMoney = function(self, n) H.poke(self, "Balance", H.peek(self, "Balance") + n) end }, { strict = true })
    local w = H.player_world({ pawn_fields = { Wallet = (not opts.no_wallet) and wallet or nil } })
    w.hud = H.obj("ExampleHUD_" .. H.world_gen, { PlayerOwner = w.pc }, { class = H.class("ExampleHUD", "Actor") })
    w.wallet = wallet
    return w
end

-- Start a scenario: forbid off-thread Lua, build the world, and let the game update the HUD every frame on the
-- game thread. Then run one frame so the mod's first read arms the key (a held key at startup must not fire).
local function boot(H, opts)
    H.config.forbid_off_thread = true
    W = build(H, opts)
    H.every_frame_hook(FRAME, function() return W and W.hud end)
end

-- press = hold the key for `hold` seconds, then release
local function press(H, hold)
    H.key_down(KEY, true); H.run(hold or 0.1); H.key_down(KEY, false); H.run(0.1)
end

return {
    setup = function(H) boot(H) end,
    scenarios = {
        {
            name = "press adds money on the game thread, no key-bind or threading API",
            run = function(H)
                H.run(0.1)                                  -- first frames arm the key
                press(H)
                H.eq(H.peek(W.wallet, "Balance"), 1000, "+1000")
                H.eq(H.log_count("+1000 added"), 1, "applied line logged")
                H.eq(H.calls.RegisterKeyBind + H.calls.RegisterKeyBindAsync, 0, "no RegisterKeyBind")
                H.eq(H.calls.LoopAsync + H.calls.ExecuteInGameThread + H.calls.ExecuteWithDelay, 0, "no threading API called")
                H.eq(H.key_reads.game and H.key_reads.game > 0, true, "key was read on the game thread")
                H.eq(H.key_reads.input, nil, "never read on the input thread")
                H.eq(#H.warnings, 0, "no warnings")
            end,
        },
        {
            name = "holding the key does one add, not one per frame",
            run = function(H)
                H.run(0.1)
                press(H, 2.0)
                H.eq(H.peek(W.wallet, "Balance"), 1000, "only one add for a 2 s hold")
                press(H)
                H.eq(H.peek(W.wallet, "Balance"), 2000, "a second press adds again")
            end,
        },
        {
            name = "a key already held at startup does not fire",
            run = function(H)
                H.key_down(KEY, true)
                H.run(1.0)
                H.eq(H.peek(W.wallet, "Balance"), 0, "held key only arms, no add")
                H.key_down(KEY, false); H.run(0.1)
                press(H)
                H.eq(H.peek(W.wallet, "Balance"), 1000, "a real press works afterwards")
            end,
        },
        {
            name = "missing object: no wallet -> fail closed, warn once",
            setup = function(H) H.reset(); boot(H, { no_wallet = true }) end,
            run = function(H)
                H.run(0.1)
                for _ = 1, 3 do press(H) end
                H.eq(H.log_count("feature disabled due to game update"), 1, "warned once")
            end,
        },
        {
            name = "game update renamed the frame function: one clear line, no key handling, no errors",
            setup = function(H) H.missing_hooks[FRAME] = true end,
            run = function(H)
                H.run(0.1)
                press(H)
                H.eq(H.log_count("feature disabled due to game update (frame hook not found"), 1, "disabled line logged once")
                H.eq(H.peek(W.wallet, "Balance"), 0, "nothing added")
            end,
        },
        {
            name = "IsInputKeyDown failing every frame: hotkey switches itself off with one line",
            setup = function(H) H.reset(); boot(H); H.poke(W.pc, "IsInputKeyDown", function() error("renamed") end) end,
            run = function(H)
                H.run(2.0)
                H.eq(H.log_count("hotkey off: IsInputKeyDown failed"), 1, "one 'hotkey off' line")
            end,
        },
        {
            name = "world change: works with the new world's objects",
            run = function(H)
                H.run(0.1)
                W = H.change_world(function() return build(H) end)
                H.run(0.1)
                press(H)
                H.eq(H.peek(W.wallet, "Balance"), 1000, "new wallet credited")
            end,
        },
        {
            name = "quit: key after QuitGame does nothing",
            run = function(H)
                H.run(0.1)
                H.quit("menu")
                H.key_down(KEY, true)
                local r = H.quit_report(1.0)
                H.eq(H.peek(W.wallet, "Balance"), 0, "no add after quit")
                H.eq(r.scheduled_after_quit, 0, "nothing scheduled after quit")
                H.eq(r.access_after_teardown, 0, "nothing touched after teardown")
            end,
        },
    },
}
