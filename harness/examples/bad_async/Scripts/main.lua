-- DELIBERATELY BAD example: this is what the harness must catch. Do not copy.
-- 1) It reads/writes UObjects inside LoopAsync (UE4SS background thread) - the #1 crash cause.
-- 2) Refill() reads IsQuitting before the `local` is declared, so it reads an always-nil global.
local function Refill()
    if IsQuitting then return true end
    local pc = FindFirstOf("PlayerController")
    if pc and pc:IsValid() then
        local ammo = pc.Pawn:GetEquippedWeapon().AmmoComponent
        if ammo.CurrentAmmo < ammo.MaxAmmo then ammo.CurrentAmmo = ammo.MaxAmmo end
    end
    return false
end

local IsQuitting = false
RegisterHook("/Script/Engine.KismetSystemLibrary:QuitGame", function() IsQuitting = true end)
LoopAsync(50, Refill)
print("[BadAsync] Loaded.")
