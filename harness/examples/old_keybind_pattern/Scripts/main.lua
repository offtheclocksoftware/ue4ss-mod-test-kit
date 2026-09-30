-- OLD PATTERN - kept to show what the off-thread check flags. Do not copy; see examples/keybind_money.
-- RegisterKeyBind runs its callback on a UE4SS thread, and ExecuteInGameThread hands the work to a queue that some UE4SS
-- builds drain from whatever thread fires ProcessEvent. Both race the mod's own game-thread hooks on the one Lua state.
-- It "works" in a quick test and has crashed games after hours. The hook-driven version in examples/keybind_money
-- reads the key on the game thread instead.
local ModName = "AddMoney"
local IsQuitting = false
local LastPress = -100
local Warned = {}

local function log(fmt, ...) print(string.format("[%s] " .. fmt, ModName, ...)) end
local function warn_once(key, fmt, ...) if not Warned[key] then Warned[key] = true; log(fmt, ...) end end
local function valid(o) local ok, r = pcall(function() return o ~= nil and o:IsValid() end) return ok and r end

local function AddMoney()
    if IsQuitting then return end
    local okpc, pc = pcall(FindFirstOf, "PlayerController")
    if not okpc or not valid(pc) then warn_once("nopc", "Not in game - key ignored.") return end
    local okw, wallet = pcall(function() return pc.Pawn.Wallet end)
    if not okw or not valid(wallet) then
        warn_once("nowallet", "WARNING: feature disabled due to game update (wallet not found).")
        return
    end
    local okadd, err = pcall(function() wallet:AddMoney(1000) end)
    if not okadd then warn_once("addfail", "WARNING: feature disabled due to game update (AddMoney failed: %s).", tostring(err)) return end
    log("+1000 added (balance %s)", tostring(wallet.Balance))
end

pcall(RegisterHook, "/Script/Engine.KismetSystemLibrary:QuitGame", function() IsQuitting = true end)

local okk = pcall(RegisterKeyBind, Key.NUM_ONE, function()
    if IsQuitting then return end
    local t = os.clock()
    if t - LastPress < 0.2 then return end            -- debounce
    LastPress = t
    ExecuteInGameThread(AddMoney)
end)
if okk then log("Loaded. Numpad 1 = +1000.") else log("WARNING: could not register Numpad 1.") end
