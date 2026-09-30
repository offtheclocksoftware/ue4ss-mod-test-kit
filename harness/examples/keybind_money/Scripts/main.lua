-- Example mod: Numpad 1 adds 1000 money.
-- Crash-safe, hook-driven hotkey (this replaces RegisterKeyBind, which is banned):
--   * RegisterKeyBind callbacks run on a UE4SS thread, not the game thread, and race the mod's own hooks.
--   * The key is read with PlayerController:IsInputKeyDown from inside a hook on a UFunction the game calls
--     every frame on its game thread (here the in-game HUD's update function), so the money change happens
--     right there, on the game thread. Nothing else runs.
--   * Edge detection: one press = one action, however long the key is held. A key already held when polling
--     starts does not fire.
--   * `self` of the hook is the HUD; HUD.PlayerOwner is the local player's controller. Nothing is cached.
-- Class and function names belong to a made-up game. Take yours from your game's reflection dump, and confirm
-- with a log line (as below) that the hook really fires before relying on it.
-- Note: numpad keys need Num Lock on (with it off, Windows sends arrows/Home/End instead). Key names are
-- Unreal FKey names ("NumPadOne", "F11", ...), not UE4SS names (Key.NUM_ONE).
local ModName = "AddMoney"
local FRAME_HOOK = "/Script/ExampleGame.ExampleHUD:UpdateHUD"
local KEY_NAME = "NumPadOne"
local MAX_KEY_FAILS = 30

-- Guard state is declared FIRST, before any function that reads it.
local IsQuitting = false
local Disabled = false
local HookFired = false
local WasDown = nil            -- nil until the first read, which only arms the key
local KeyFails = 0
local Warned = {}
local Key = { KeyName = FName(KEY_NAME) }

local function log(fmt, ...) print(string.format("[%s] " .. fmt, ModName, ...)) end
local function warn_once(key, fmt, ...) if not Warned[key] then Warned[key] = true; log(fmt, ...) end end
local function valid(o) local ok, r = pcall(function() return o ~= nil and o:IsValid() end) return ok and r end
local function unwrap(p) local v = p; pcall(function() if p and p.get then v = p:get() end end) return v end

local function AddMoney(pc)
    local okw, wallet = pcall(function() return pc.Pawn.Wallet end)
    if not okw or not valid(wallet) then
        warn_once("nowallet", "WARNING: feature disabled due to game update (wallet not found).")
        return
    end
    local okadd, err = pcall(function() wallet:AddMoney(1000) end)
    if not okadd then warn_once("addfail", "WARNING: feature disabled due to game update (AddMoney failed: %s).", tostring(err)) return end
    log("+1000 added (balance %s)", tostring(wallet.Balance))
end

-- Runs on the game thread: the game calls UpdateHUD itself, every frame.
local function OnFrame(self)
    if IsQuitting or Disabled then return end
    if not HookFired then HookFired = true; log("Frame hook is firing (game thread).") end
    local hud = unwrap(self)
    if not valid(hud) then WasDown = nil return end
    local okc, pc = pcall(function() return hud.PlayerOwner end)
    if not okc or not valid(pc) then WasDown = nil return end
    local okd, down = pcall(function() return pc:IsInputKeyDown(Key) end)
    if not okd or type(down) ~= "boolean" then
        KeyFails = KeyFails + 1
        if KeyFails >= MAX_KEY_FAILS then
            Disabled = true
            log("WARNING: hotkey off: IsInputKeyDown failed %d times - game update?", KeyFails)
        end
        return
    end
    KeyFails = 0
    if WasDown == nil then WasDown = down return end        -- first read only arms the key
    if down and not WasDown then AddMoney(pc) end
    WasDown = down
end

local okq = pcall(RegisterHook, "/Script/Engine.KismetSystemLibrary:QuitGame", function() IsQuitting = true end)
if not okq then log("QuitGame hook not available (continuing).") end

local okt, err = pcall(RegisterHook, FRAME_HOOK, function(self) OnFrame(self) end)
if okt then
    log("Loaded. Numpad 1 = +1000.")
else
    Disabled = true
    log("WARNING: feature disabled due to game update (frame hook not found: %s).", tostring(err))
end
