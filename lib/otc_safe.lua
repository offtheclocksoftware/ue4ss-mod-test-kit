--[[
  otc_safe.lua  -  defensive helpers for UE4SS Lua mods (Off the Clock) v1.1
  SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software

  Copy it next to main.lua in <Mod>/Scripts/ and load it with a small loader in main.lua
  (require("otc_safe"), falling back to dofile; see examples/FasterSprint/ for the loader):

      local Safe = <loader>()
      local S = Safe.new("[MyMod]", { verbose = false })

  Goals
    * A hook/lookup that no longer exists after a game patch -> ONE clear log line
      ("feature disabled: X - game update changed Y") and the feature goes idle. Never a crash, never spam.
    * Never treat an invalid UObject as "found". FindFirstOf / StaticFindObject return an
      INVALID object (not nil) when nothing matches, so `if obj then` is not a check.
    * Game-object work runs on the game thread, i.e. INSIDE a hook callback (safe_hook /
      on_restart / safe_notify). Never from ExecuteWithDelay / LoopAsync / key callbacks.

  v1.1 - NO ExecuteInGameThread by default
    Why (a crash-on-quit investigated across 70+ crash dumps in one Unreal game):
      - The UE4SS build in use (v3.0.1 Beta, git f08dfdf) resolved
        "GameModeBase::InitGameState" to the wrong function (it was really
        AGameModeBase::MustSpectate_Implementation(APlayerController*)). UE4SS always hooks it,
        and its one-argument detour drops the PlayerController argument, so the game reads a
        pointer out of UE4SS's stack.
      - The first ExecuteInGameThread call installs UE4SS's ProcessEvent hook. With that hook in
        the call chain the garbage pointer lands on a non-pointer value and the game crashes
        when it runs MustSpectate during the quit / map change (LoadMap) path. Mods that never
        call ExecuteInGameThread leave that slot null (no crash), which matched a clean
        zero-mod test.
    So v1.1:
      - run_gt() only runs code that is already on the game thread (inside a hook callback
        registered through this helper). Called from anywhere else it refuses and disables
        the feature with one log line.
      - after(), loop() and safe_key() need ExecuteInGameThread. They are OFF unless the mod
        opts in with Safe.new(prefix, { allow_game_thread_queue = true }), which logs a warning.
        Prefer on_restart()/safe_hook() work done synchronously in the callback.
      - New: on_restart(fn, label) = PlayerController:ClientRestart POST hook, fn(pc, pawn)
        on the game thread with already-unwrapped, validated objects. No timers.
      - New: debounce(key, seconds) (wall clock; os.clock() is CPU time).
    Tip for users: UE4SS-settings.ini [Hooks] HookInitGameState = 0 removes the bad hook
    entirely (that fixes it for every mod; test it before recommending it).

  Works with UE4SS 3.x Lua 5.4. No `...` inside non-vararg closures.
]]

local M = {}
M.__index = M

local unpack = table.unpack or unpack

-- Sentinel a loop body can return to stop its loop cleanly.
M.STOP = setmetatable({}, { __tostring = function() return "Safe.STOP" end })

---------------------------------------------------------------------------
-- construction / logging
---------------------------------------------------------------------------

function M.new(prefix, opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.prefix = tostring(prefix or "[Mod]")
    self.verbose = opts.verbose == true
    self.max_hook_errors = tonumber(opts.max_hook_errors) or 5
    self.max_loop_failures = tonumber(opts.max_loop_failures) or 10
    self._warned = {}    -- key -> true (warn-once)
    self._disabled = {}  -- feature -> reason
    self._errors = {}    -- label -> count
    self._gt_depth = 0   -- >0 while inside a hook callback registered through this helper
    self._debounce = {}  -- key -> os.time() of last accept
    self.allow_gtq = opts.allow_game_thread_queue == true
    if self.allow_gtq then
        self:log("WARN allow_game_thread_queue is on: this mod uses ExecuteInGameThread, which has crashed games on quit with some UE4SS builds (InitGameState hook bug)")
    end
    return self
end

local function fmt(f, ...)
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, tostring(f), ...)
    if ok then return s end
    return tostring(f) .. " [format error]"
end

function M:log(f, ...)
    print(self.prefix .. " " .. fmt(f, ...) .. "\n")
end

function M:debug(f, ...)
    if self.verbose then self:log(f, ...) end
end

-- Log the first time `key` is seen; stay silent afterwards. Returns true if it logged.
function M:warn_once(key, f, ...)
    key = tostring(key)
    if self._warned[key] then return false end
    self._warned[key] = true
    self:log("WARN " .. fmt(f, ...))
    return true
end

-- Feature kill-switch: logs exactly once, then enabled(feature) returns false.
function M:disable(feature, reason)
    feature = tostring(feature)
    if self._disabled[feature] then return end
    self._disabled[feature] = tostring(reason or "unknown")
    self:log("feature disabled: %s - %s (rest of mod keeps running)", feature, self._disabled[feature])
end

function M:enabled(feature)
    return self._disabled[tostring(feature)] == nil
end

-- Standard wording for "a game patch moved something we depend on".
function M:disable_changed(feature, what)
    self:disable(feature, "game update changed " .. tostring(what))
end

---------------------------------------------------------------------------
-- UObject basics
---------------------------------------------------------------------------

-- True only for a live UObject. Safe on nil, numbers, tables and invalid wrappers.
function M.is_valid(obj)
    if obj == nil then return false end
    local t = type(obj)
    if t ~= "userdata" and t ~= "table" then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- Stable identity for a UObject (address), or nil.
function M.addr(obj)
    if not M.is_valid(obj) then return nil end
    local ok, a = pcall(function() return obj:GetAddress() end)
    if ok and a ~= nil then return a end
    return nil
end

-- True if a and b are the same live UObject.
function M.same(a, b)
    local x = M.addr(a)
    return x ~= nil and x == M.addr(b)
end

-- RemoteUnrealParam / hook params -> underlying value (bounded, never throws).
function M.unwrap(v)
    local cur = v
    for _ = 1, 4 do
        if cur == nil then return nil end
        local ok, nxt = pcall(function()
            if type(cur.get) == "function" then return cur:get() end
            return nil
        end)
        if not ok or nxt == nil then break end
        cur = nxt
    end
    return cur
end

-- Returns a VALID object or nil (never an invalid wrapper). Warns once per label.
function M:safe_find(class, label)
    label = label or ("FindFirstOf " .. tostring(class))
    local ok, obj = pcall(FindFirstOf, class)
    if ok and M.is_valid(obj) then return obj end
    if not ok then self:warn_once("find:" .. label, "%s threw: %s", label, tostring(obj)) end
    self:debug("%s: no valid instance", label)
    return nil
end

-- Returns an array of VALID objects (possibly empty). FindAllOf returns nil when none.
function M:safe_find_all(class, label)
    local out = {}
    local ok, list = pcall(FindAllOf, class)
    if not ok then
        self:warn_once("findall:" .. tostring(label or class), "FindAllOf %s threw: %s", tostring(class), tostring(list))
        return out
    end
    if type(list) ~= "table" then return out end
    for _, o in pairs(list) do
        if M.is_valid(o) then out[#out + 1] = o end
    end
    return out
end

-- StaticFindObject wrapper: valid object or nil + warn-once (class/CDO paths get renamed).
function M:safe_static(path, label)
    local ok, obj = pcall(StaticFindObject, path)
    if ok and M.is_valid(obj) then return obj end
    self:warn_once("static:" .. tostring(label or path), "StaticFindObject '%s' not found%s",
        tostring(path), ok and "" or (" (" .. tostring(obj) .. ")"))
    return nil
end

-- Read a property only if the object is valid and the value has the expected Lua type
-- ("number", "boolean", "string", "userdata"). Missing -> nil + warn once per label.
function M:get(obj, prop, expect_type, label)
    if not M.is_valid(obj) then return nil end
    local ok, v = pcall(function() return obj[prop] end)
    if ok and v ~= nil and (expect_type == nil or type(v) == expect_type) then return v end
    self:warn_once("get:" .. tostring(label or prop),
        "property '%s' missing or not %s (got %s)", tostring(prop), tostring(expect_type or "any"),
        ok and type(v) or ("error: " .. tostring(v)))
    return nil
end

-- Numeric write with type guard + read-back. Refuses to write if the current value is not
-- a number (property renamed / retyped by a patch). Returns true on verified write.
function M:set_num(obj, prop, value, label)
    local cur = self:get(obj, prop, "number", label)
    if cur == nil then return false end
    if math.abs(cur - value) < 1e-4 then return true end
    local ok, err = pcall(function() obj[prop] = value end)
    if not ok then
        self:warn_once("set:" .. tostring(label or prop), "write %s failed: %s", tostring(prop), tostring(err))
        return false
    end
    local after = self:get(obj, prop, "number", label)
    return after ~= nil and math.abs(after - value) < 1e-3
end

-- 0-based TArray read using UE4SS's 1-based indexing. ONE style only: no fallback that
-- could silently address a different element.
function M.arr_num(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    return 0
end

function M.arr_get(arr, index0)
    if index0 < 0 or index0 >= M.arr_num(arr) then return nil end
    local ok, v = pcall(function() return arr[index0 + 1] end)
    if ok then return v end
    return nil
end

---------------------------------------------------------------------------
-- threading
---------------------------------------------------------------------------

-- True while we are inside a hook/notify callback registered through this helper (game thread).
function M:in_game_thread()
    return (self._gt_depth or 0) > 0
end

-- Run fn(...) inside pcall under the game-thread marker. Used by the hook guards.
function M:_run_marked(label, fn, ...)
    self._gt_depth = (self._gt_depth or 0) + 1
    local ok, err = pcall(fn, ...)
    self._gt_depth = self._gt_depth - 1
    return ok, err
end

local NEED_QUEUE = "needs ExecuteInGameThread, which has crashed games on quit with some UE4SS builds (InitGameState hook bug); do the work inside a hook callback instead"

-- Run fn(...) on the game thread inside pcall. Errors are logged once per label.
-- v1.1: runs directly when already inside a helper hook callback. Anywhere else it only
-- queues via ExecuteInGameThread if the mod opted in (allow_game_thread_queue); otherwise the
-- feature is disabled with one log line and nothing runs.
function M:run_gt(label, fn, ...)
    local args = { n = select("#", ...), ... }
    local selfref = self
    local function body()
        local ok, err = selfref:_run_marked(label, fn, unpack(args, 1, args.n))
        if not ok then
            selfref._errors[label] = (selfref._errors[label] or 0) + 1
            selfref:warn_once("gt:" .. tostring(label), "%s error: %s", tostring(label), tostring(err))
        end
    end
    if self:in_game_thread() then
        body()
        return true
    end
    if self.allow_gtq and type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(body)
        return true
    end
    self:disable(label, NEED_QUEUE)
    return false
end

-- One-shot delay that lands on the game thread. v1.1: opt-in only (see header).
function M:after(ms, label, fn)
    if not self.allow_gtq then
        self:disable(label, "delayed call " .. NEED_QUEUE)
        return false
    end
    local selfref = self
    if type(ExecuteWithDelay) ~= "function" then
        return selfref:run_gt(label, fn)
    end
    ExecuteWithDelay(ms, function() selfref:run_gt(label, fn) end)
    return true
end

--[[
  Repeating game-thread loop with back-off. v1.1: opt-in only (allow_game_thread_queue).
    fn() may:  return Safe.STOP   -> loop ends quietly (e.g. target reached)
               return false, why  -> counts as a failure (lookup missing etc.)
               error(...)         -> counts as a failure
               anything else      -> success, failure streak resets
  After max_loop_failures consecutive failures the loop stops and disables `label`.
  Never queues a new game-thread task while the previous one is still pending.
]]
function M:loop(ms, label, fn, opts)
    opts = opts or {}
    local max_fail = tonumber(opts.max_failures) or self.max_loop_failures
    local selfref = self
    local st = { fails = 0, stop = false, busy = false, last_why = nil }
    if not self.allow_gtq then
        st.stop = true
        self:disable(label, "loop " .. NEED_QUEUE)
        return st
    end
    local function tick()
        local ok, r, why = pcall(fn)
        if not ok then
            st.fails, st.last_why = st.fails + 1, tostring(r)
        elseif r == M.STOP then
            st.stop = true
        elseif r == false then
            st.fails, st.last_why = st.fails + 1, tostring(why or "returned false")
        else
            st.fails = 0
        end
        if st.fails >= max_fail then
            st.stop = true
            selfref:disable(label, string.format("%d consecutive failures, last: %s", st.fails, tostring(st.last_why)))
        end
        st.busy = false
    end
    if type(LoopAsync) ~= "function" or type(ExecuteInGameThread) ~= "function" then
        self:warn_once("loop:" .. label, "LoopAsync/ExecuteInGameThread unavailable; loop '%s' not started", label)
        return st
    end
    LoopAsync(ms, function()
        if st.stop or not selfref:enabled(label) then return true end
        if st.busy then return false end
        st.busy = true
        ExecuteInGameThread(function() selfref:_run_marked(label, tick) end)
        return false
    end)
    return st
end

-- Wall-clock debounce: true if `key` was not accepted in the last `seconds` seconds.
function M:debounce(key, seconds)
    key = tostring(key)
    local now = os.time()
    local last = self._debounce[key]
    if last ~= nil and (now - last) < (tonumber(seconds) or 0) then return false end
    self._debounce[key] = now
    return true
end

---------------------------------------------------------------------------
-- registration
---------------------------------------------------------------------------

-- RegisterHook that (a) never throws if the UFunction path vanished, (b) logs one clear
-- line either way, (c) pcall-guards the callback, (d) goes idle (no-op) after
-- max_hook_errors callback errors instead of erroring on every call.
-- Returns pre_id, post_id on success, nil otherwise.
function M:safe_hook(path, fn, label, post_fn)
    label = label or path
    local selfref = self
    local function guard(which, f)
        return function(ctx, ...)
            if not selfref:enabled(label) then return end
            local ok, err = selfref:_run_marked(label, f, ctx, ...)
            if not ok then
                local n = (selfref._errors[label] or 0) + 1
                selfref._errors[label] = n
                selfref:warn_once("hook:" .. label .. which, "hook %s (%s) error: %s", label, which, tostring(err))
                if n >= selfref.max_hook_errors then
                    selfref:disable(label, "hook callback failed " .. n .. " times")
                end
            end
        end
    end
    local ok, pre_id, post_id = pcall(function()
        if post_fn then
            return RegisterHook(path, guard("pre", fn), guard("post", post_fn))
        end
        return RegisterHook(path, guard("pre", fn))
    end)
    if ok then
        self:log("hooked %s", path)
        return pre_id, post_id
    end
    self:debug("RegisterHook %s failed: %s", tostring(path), tostring(pre_id))
    self:disable_changed(label, tostring(path) .. " (hook not found)")
    return nil
end

-- NotifyOnNewObject with the same guarantees. Note: the new object is only
-- partially initialised: do not touch it here. Use it as a signal only, or use on_restart().
function M:safe_notify(class_path, fn, label)
    label = label or ("new " .. tostring(class_path))
    local selfref = self
    local ok, err = pcall(function()
        NotifyOnNewObject(class_path, function(obj)
            if not selfref:enabled(label) then return end
            local ok2, e2 = selfref:_run_marked(label, fn, obj)
            if not ok2 then selfref:warn_once("notify:" .. label, "%s error: %s", label, tostring(e2)) end
        end)
    end)
    if ok then
        self:log("watching %s", class_path)
        return true
    end
    self:debug("NotifyOnNewObject %s failed: %s", tostring(class_path), tostring(err))
    self:disable_changed(label, tostring(class_path) .. " (class not found)")
    return false
end

-- PlayerController:ClientRestart POST hook (runs after the controller took the pawn), on the
-- game thread. fn(pc, pawn) gets unwrapped objects; both are checked with is_valid first.
-- Returns true if the hook is registered. Nothing is cached between calls.
function M:on_restart(fn, label)
    label = label or "ClientRestart"
    local selfref = self
    local post = function(ctx, newPawn)
        local pc = M.unwrap(ctx)
        local pawn = M.unwrap(newPawn)
        if not M.is_valid(pc) then return end
        if not M.is_valid(pawn) then
            pawn = nil
            pcall(function() pawn = M.unwrap(pc.Pawn) end)
            if not M.is_valid(pawn) then pawn = nil end
        end
        fn(pc, pawn)
    end
    local pre = function() end
    local pre_id = self:safe_hook("/Script/Engine.PlayerController:ClientRestart", pre, label, post)
    return pre_id ~= nil
end

-- RegisterKeyBind. v1.1: key callbacks are NOT on the game thread, so the callback is queued
-- with ExecuteInGameThread and therefore needs allow_game_thread_queue (see header).
-- key: Key.X ; mods: optional { ModifierKey.CONTROL, ... }
function M:safe_key(key, mods, fn, label)
    label = label or "key"
    if key == nil then
        self:warn_once("key:" .. label, "key for '%s' is nil in this UE4SS build; not bound", label)
        return false
    end
    if not self.allow_gtq then
        self:disable(label, "hotkey " .. NEED_QUEUE)
        return false
    end
    local selfref = self
    local cb = function() selfref:run_gt(label, fn) end
    local ok, err = pcall(function()
        if mods then RegisterKeyBind(key, mods, cb) else RegisterKeyBind(key, cb) end
    end)
    if ok then
        self:debug("bound %s", label)
        return true
    end
    self:warn_once("key:" .. label, "RegisterKeyBind '%s' failed: %s", label, tostring(err))
    return false
end

---------------------------------------------------------------------------
-- console commands (they never throw for unknown commands - verify effects yourself)
---------------------------------------------------------------------------

function M:console(world, cmd, pc)
    local kismet = self:safe_static("/Script/Engine.Default__KismetSystemLibrary", "KismetSystemLibrary")
    if not kismet or not M.is_valid(world) then return false end
    local ok, err = pcall(function() kismet:ExecuteConsoleCommand(world, cmd, pc) end)
    if not ok then self:warn_once("cmd:" .. cmd, "console '%s' failed: %s", cmd, tostring(err)) end
    return ok -- NOTE: true only means "dispatched", not "the command exists"
end

return M
