--[[
fake_ue4ss.lua - offline fake of the UE4SS Lua API, for testing mods without the game.

Loaded by run.lua. Everything lives in the global table `H` (also returned).
It is a behavioral model, not the real engine. See README.md for what it can and can't catch.

Simulated threads (H.thread):
  "load"  - the mod's main.lua running at startup
  "game"  - Unreal game thread: hook callbacks, NotifyOnNewObject, ExecuteInGameThread queue
  "async" - UE4SS background thread: LoopAsync, ExecuteWithDelay, ExecuteAsync, RegisterKeyBindAsync
  "input" - UE4SS key-input thread: RegisterKeyBind callbacks (configurable, see H.config.keybind_thread)
  "test"  - the scenario itself (never flagged)

The #1 crash cause this kit exists to catch: touching a UObject from the "async" thread.
Every UObject read, write, method call, and every Find*/StaticFindObject/StaticConstructObject
call made on "async" is recorded as a violation with the mod's file:line.

SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
]]

local H = {}
_G.H = H

local HARNESS_FILE = "fake_ue4ss.lua"
local unpack = table.unpack or unpack

-- ------------------------------------------------------------------ config
local function default_config()
    return {
        tick_ms = 25,                    -- one simulated frame
        executor_alive = true,           -- ExecuteInGameThread queue runs (UE4SS runs it from its ProcessEvent hook;
                                         -- with HookUObjectProcessEvent = 0 in UE4SS-settings.ini it may never run)
        keybind_thread = "input",        -- where RegisterKeyBind callbacks run: "input" (default), "game", or "async"
        strict_input_thread = false,     -- true = UObject access from the input thread fails the scenario (else warning)
        warn_load_access = false,        -- true = warn on UObject access while main.lua is loading
        has_loop_in_game_thread = false, -- LoopInGameThreadWithDelay / ExecuteInGameThreadWithDelay exist in this UE4SS build
        teardown_ticks = 2,              -- frames between QuitGame and world teardown (objects become invalid)
        echo_log = false,                -- also print mod log lines live
        warn_undefined_globals = true,   -- warn when mod code reads a global that was never assigned
        -- true = the mod may not run ANY Lua off the game thread: registering RegisterKeyBind, RegisterKeyBindAsync, ExecuteInGameThread,
        -- LoopAsync, ExecuteAsync, ExecuteWithDelay or any of the InGameThread delayed family (ExecuteInGameThreadWithDelay,
        -- LoopInGameThreadWithDelay, RetriggerableExecuteInGameThreadWithDelay, ExecuteInGameThreadAfterFrames,
        -- LoopInGameThreadAfterFrames) is a failure, and so is any callback that runs on the "async" or "input" thread.
        -- The safe rule for every UE4SS game: UE4SS runs those callbacks on its own threads, concurrently with the mod's
        -- game-thread hooks, and a mod has a single Lua state (a crash after ~1.5 h idle was traced to exactly this).
        -- Set it in a scenario's setup, or for a whole run with the environment variable HARNESS_FORBID_OFF_THREAD=1.
        forbid_off_thread = os.getenv("HARNESS_FORBID_OFF_THREAD") == "1",
    }
end

-- ------------------------------------------------------------------ helpers
local function where()
    -- first stack frame outside the harness files = the mod (or scenario) line responsible
    for level = 3, 40 do
        local info = debug.getinfo(level, "Sl")
        if not info then break end
        local src = info.source or ""
        if src:sub(1, 1) == "@" and not src:find(HARNESS_FILE, 1, true) and not src:match("[/\\]run%.lua$") and src ~= "@run.lua"
           and not src:match("[/\\]otc_safe%.lua$") then   -- otc_safe wrappers (S:after/S:loop/S:safe_key): report the mod's own call site
            return (info.short_src or src):gsub("^.*[/\\]", "") .. ":" .. tostring(info.currentline)
        end
    end
    return "?"
end

local function mod_frame()
    -- true when the calling code (2 levels up) is inside the mod's own folder
    if not H.mod_dir then return false end
    local info = debug.getinfo(3, "S")
    if not info or not info.source then return false end
    local src = info.source:gsub("\\", "/")
    return src:sub(1, 1) == "@" and src:find(H.mod_dir, 1, true) ~= nil
end

local function add_unique(list, seen, key, rec)
    if seen[key] then seen[key].count = seen[key].count + 1 return end
    rec.count = 1
    seen[key] = rec
    list[#list + 1] = rec
end

function H.warn(msg, key)
    add_unique(H.warnings, H._warn_seen, key or msg, { msg = msg })
end

local function record_error(context, err)
    local rec = { context = context, err = tostring(err), at = H.now }
    H.errors[#H.errors + 1] = rec
    H.log[#H.log + 1] = string.format("%8.3f [harness] Lua error in %s: %s", H.now, context, tostring(err))
end

-- forbid_off_thread: an off-game-thread API was registered, or a callback ran on "async"/"input"
local function off_thread(kind, what, at)
    if not H.config.forbid_off_thread then return end
    add_unique(H.violations, H._viol_seen, kind .. "|" .. at .. "|" .. what,
        { kind = kind, thread = H.thread, what = what, where = at })
end
H._off_thread = off_thread

-- run fn on a simulated thread, catching errors the way UE4SS does (it logs them; the game keeps going)
local function on_thread(thread, context, fn, ...)
    if thread == "async" or thread == "input" then off_thread("off-thread-callback", context .. " ran on the " .. thread .. " thread", context) end
    local prev = H.thread
    H.thread = thread
    local res = table.pack(xpcall(fn, debug.traceback, ...))
    H.thread = prev
    if not res[1] then record_error(context, res[2]) return nil end
    return unpack(res, 2, res.n)
end

-- ------------------------------------------------------------------ UObject model
local D = setmetatable({}, { __mode = "k" })   -- proxy -> internal data
H._D = D
local OBJ_MT = {}
local next_addr = 0x10000

local function touch(d, what)
    local t = H.thread
    H.touches[t] = (H.touches[t] or 0) + 1
    H.accesses[what] = (H.accesses[what] or 0) + 1
    if H.quit_state == "torn_down" and t ~= "test" then
        add_unique(H.violations, H._viol_seen, "teardown|" .. where() .. "|" .. what,
            { kind = "after-teardown", thread = t, what = what, where = where() })
    end
    if t == "async" then
        add_unique(H.violations, H._viol_seen, "async|" .. where() .. "|" .. what,
            { kind = "background-thread", thread = t, what = what, where = where() })
    elseif t == "input" then
        if H.config.strict_input_thread then
            add_unique(H.violations, H._viol_seen, "input|" .. where() .. "|" .. what,
                { kind = "input-thread", thread = t, what = what, where = where() })
        else
            H.warn(string.format("UObject access from the key-input thread: %s at %s (hand it to the game thread if this build runs keybinds off-thread)", what, where()),
                "input|" .. where())
        end
    elseif t == "load" and H.config.warn_load_access then
        H.warn(string.format("UObject access during mod load: %s at %s", what, where()), "load|" .. where())
    end
end
H._touch = touch

local function new_proxy(d)
    next_addr = next_addr + 0x10
    d.addr = next_addr
    d.gen = H.world_gen
    local p = setmetatable({}, OBJ_MT)
    D[p] = d
    H.all_objects[#H.all_objects + 1] = p
    return p
end

local FNAME_MT = {
    __index = { ToString = function(self) return self.s end },
    __tostring = function(self) return self.s end,
    __eq = function(a, b) return a.s == b.s end,
}
function FName(s) if type(s) == "table" and s.s then return s end return setmetatable({ s = tostring(s) }, FNAME_MT) end
function FText(s) return setmetatable({ s = tostring(s) }, FNAME_MT) end
function FString(s) return setmetatable({ s = tostring(s) }, FNAME_MT) end

local builtins = {}
function builtins.IsValid(d) return function() return d.valid end end
function builtins.GetFullName(d) return function() return (d.class and D[d.class].name or "Object") .. " " .. d.path end end
function builtins.GetFName(d) return function() return FName(d.name) end end
function builtins.GetAddress(d) return function() return d.addr end end
function builtins.GetClass(d) return function() return d.class or H.invalid end end
function builtins.GetOuter(d) return function() return d.outer or H.invalid end end
function builtins.IsA(d)
    return function(_, cls)
        local c = d.class
        if type(cls) == "string" then
            while c do local cd = D[c]; if cd.name == cls or cd.path == cls then return true end; c = cd.parent end
            return false
        end
        while c do if rawequal(c, cls) then return true end; c = D[c].parent end
        return false
    end
end
function builtins.type(d) return function() return d.is_class and "UClass" or "UObject" end end
function builtins.GetWorld(d) return function() return H.world or H.invalid end end

-- PlayerController input API (only on objects whose class chain contains "PlayerController").
-- Key state comes from H.key_down(name, down); key = FKey table { KeyName = FName("NumPadFour") } (or a string).
local function key_name(key)
    if type(key) == "table" and not D[key] then key = key.KeyName end
    if type(key) == "table" and key.s then return key.s end
    return tostring(key)
end
local function is_pc(d)
    local c = d.class
    while c do if D[c].name == "PlayerController" then return true end; c = D[c].parent end
    return false
end
local pc_builtins = {}
function pc_builtins.IsInputKeyDown()
    return function(_, key)
        H.calls.IsInputKeyDown = H.calls.IsInputKeyDown + 1
        H.key_reads[H.thread] = (H.key_reads[H.thread] or 0) + 1
        return H.keys[key_name(key)] == true
    end
end
function pc_builtins.WasInputKeyJustPressed()
    return function(_, key)
        H.calls.WasInputKeyJustPressed = H.calls.WasInputKeyJustPressed + 1
        H.key_reads[H.thread] = (H.key_reads[H.thread] or 0) + 1
        return H.key_pressed_frame[key_name(key)] == H.frame
    end
end

OBJ_MT.__index = function(p, k)
    local d = D[p]
    touch(d, d.name .. "." .. tostring(k))
    if k == "IsValid" then return builtins.IsValid(d) end
    if not d.valid then
        error(string.format("[harness] accessed '%s' on an invalid/destroyed UObject (%s) - check IsValid() first", tostring(k), d.name), 2)
    end
    local v = d.fields[k]
    if v ~= nil then return v end
    local b = builtins[k]
    if b then return b(d) end
    if pc_builtins[k] and is_pc(d) then return pc_builtins[k](d) end
    if d.strict then error(string.format("[harness] %s has no property or function '%s'", d.name, tostring(k)), 2) end
    return nil
end
OBJ_MT.__newindex = function(p, k, v)
    local d = D[p]
    touch(d, d.name .. "." .. tostring(k) .. " (write)")
    if not d.valid then
        error(string.format("[harness] wrote '%s' on an invalid/destroyed UObject (%s)", tostring(k), d.name), 2)
    end
    if d.strict and d.fields[k] == nil then error(string.format("[harness] %s has no property '%s'", d.name, tostring(k)), 2) end
    d.fields[k] = v
    if H.on_write then H.on_write(p, k, v) end
end
OBJ_MT.__eq = function(a, b) return D[a] and D[b] and D[a].addr == D[b].addr end
OBJ_MT.__tostring = function(p) return "UObject<" .. D[p].name .. ">" end

local function class_names(cls)
    local names = {}
    local c = cls
    while c do local cd = D[c]; names[#names + 1] = cd.name; names[#names + 1] = cd.path; c = cd.parent end
    return names
end

--- H.class(name, parent_class_or_nil, path_or_nil) -> class object (persistent, survives world change)
function H.class(name, parent, path)
    if type(parent) == "string" then parent = H.classes[parent] or H.class(parent) end
    if H.classes[name] then return H.classes[name] end
    local c = new_proxy({ name = name, path = path or ("/Script/Game." .. name), fields = {}, valid = true,
                          persistent = true, is_class = true, parent = parent })
    H.classes[name] = c
    if path then H.classes[path] = c end
    H.statics[path or ("/Script/Game." .. name)] = c
    return c
end

--[[ H.obj(name, fields, opts) -> fake UObject
  fields: table of properties and methods. Methods are called with the object first (obj:Method(...)).
  opts.class      class object or class name (default: a class named after `name` without _C_0-style suffix)
  opts.persistent true = survives world change / teardown (class default objects, statics)
  opts.strict     true = reading/writing an unknown member raises an error (like a renamed property)
  opts.find       false = not returned by FindFirstOf/FindAllOf
  opts.path       object path for StaticFindObject (also registers it there)
]]
function H.obj(name, fields, opts)
    opts = opts or {}
    local cls = opts.class
    if type(cls) == "string" or cls == nil then
        local cname = cls or (name:gsub("_%d+$", ""))
        cls = H.classes[cname] or H.class(cname)
    end
    local p = new_proxy({ name = name, path = opts.path or ("/Game/Fake." .. name), fields = fields or {}, valid = true,
                          persistent = opts.persistent, strict = opts.strict, class = cls, outer = opts.outer })
    if opts.find ~= false then
        for _, n in ipairs(class_names(cls)) do
            H.by_class[n] = H.by_class[n] or {}
            table.insert(H.by_class[n], p)
        end
    end
    if opts.path then H.statics[opts.path] = p end
    return p
end

--- Mark an object destroyed (IsValid() -> false; any other access raises an error).
function H.destroy(p) if D[p] then D[p].valid = false end end
--- Read/write a field from the scenario without counting as mod access (works on destroyed objects too).
function H.peek(p, k) return D[p].fields[k] end
function H.poke(p, k, v) D[p].fields[k] = v end
function H.is_alive(p) return D[p] and D[p].valid end

--- UE4SS hook/params style wrapper: param:get() / param:set(v)
function H.param(v)
    return setmetatable({ _v = v }, { __index = {
        get = function(self) return self._v end,
        set = function(self, x) self._v = x end,
        type = function() return "RemoteUnrealParam" end } })
end
local function is_param(x)
    if type(x) ~= "table" or D[x] then return false end
    return type(x.get) == "function" and type(x.set) == "function"
end

--- TArray-like wrapper (1-based, like UE4SS): arr[i], #arr, arr:GetArrayNum(), arr:ForEach(function(i, elem) elem:get() end)
function H.array(list)
    list = list or {}
    local mt = {}
    local a = setmetatable({}, mt)
    local d = { name = "TArray", valid = true, fields = {} }
    mt.__index = function(_, k)
        touch(d, "TArray[" .. tostring(k) .. "]")
        if type(k) == "number" then return list[k] end
        if k == "GetArrayNum" then return function() return #list end end
        if k == "ForEach" then return function(_, f) for i, v in ipairs(list) do if f(i, H.param(v)) == true then break end end end end
        if k == "IsValid" then return function() return true end end
        if k == "Empty" then return function() for i = #list, 1, -1 do list[i] = nil end end end
        return nil
    end
    mt.__newindex = function(_, k, v) touch(d, "TArray[" .. tostring(k) .. "] (write)"); list[k] = v end
    mt.__len = function() touch(d, "TArray length"); return #list end
    return a, list
end

Key = setmetatable({}, { __index = function(_, k) return k end })
ModifierKey = setmetatable({}, { __index = function(_, k) return k end })

-- ------------------------------------------------------------------ UE4SS API fakes
local function count(name) H.calls[name] = (H.calls[name] or 0) + 1 end
local function api_touch(name, arg)
    count(name)
    touch({ name = name }, name .. "(" .. tostring(arg) .. ")")
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local s = table.concat(parts, "\t"):gsub("\r?\n$", "")
    H.log[#H.log + 1] = string.format("%8.3f %s", H.now, s)
    if H.config.echo_log then io.write("      | ", s, "\n") end
end

function RegisterHook(path, pre, post)
    count("RegisterHook")
    if H.missing_hooks[path] or (H.known_hooks and not H.known_hooks[path]) then
        error("No UFunction with the specified name was found: " .. tostring(path), 2)
    end
    if type(pre) ~= "function" then error("RegisterHook: pre-callback must be a function", 2) end
    H.hooks[path] = H.hooks[path] or {}
    H.hook_id = H.hook_id + 2
    table.insert(H.hooks[path], { pre = pre, post = post, id = H.hook_id })
    return H.hook_id, H.hook_id + 1
end

function UnregisterHook(path, pre_id)
    local list = H.hooks[path] or {}
    for i = #list, 1, -1 do if list[i].id == pre_id then table.remove(list, i) end end
end

function NotifyOnNewObject(cls, cb)
    count("NotifyOnNewObject")
    H.notify[#H.notify + 1] = { cls = cls, cb = cb }
end

local function keybind(async, key, a, b)
    count(async and "RegisterKeyBindAsync" or "RegisterKeyBind")
    off_thread("off-thread-api", (async and "RegisterKeyBindAsync(" or "RegisterKeyBind(") .. tostring(key) .. ")", where())
    local mods, cb = {}, b
    if type(a) == "function" then cb, mods = a, {} else mods = a or {} end
    if type(cb) ~= "function" then error("RegisterKeyBind: callback must be a function", 3) end
    H.keybinds[#H.keybinds + 1] = { key = key, mods = mods, cb = cb, async = async }
end
function RegisterKeyBind(key, a, b) return keybind(false, key, a, b) end
function RegisterKeyBindAsync(key, a, b) return keybind(true, key, a, b) end
function IsKeyBindRegistered(key)
    for _, k in ipairs(H.keybinds) do if k.key == key then return true end end
    return false
end

function ExecuteInGameThread(f)
    count("ExecuteInGameThread")
    off_thread("off-thread-api", "ExecuteInGameThread()", where())   -- UE4SS may drain it on any thread
    if type(f) ~= "function" then error("ExecuteInGameThread expects a function", 2) end
    if H.quit_state then H.scheduled_after_quit = H.scheduled_after_quit + 1 end
    H.gt_queue[#H.gt_queue + 1] = { f = f, where = where() }
    if #H.gt_queue > H.max_queue then H.max_queue = #H.gt_queue end
end

local function add_timer(kind, ms, f, loop)
    if type(f) ~= "function" then error("callback must be a function", 3) end
    if H.quit_state then H.scheduled_after_quit = H.scheduled_after_quit + 1 end
    local t = { kind = kind, ms = ms or 0, f = f, at = H.now + (ms or 0) / 1000, loop = loop, where = where() }
    H.timers[#H.timers + 1] = t
    return t
end
function LoopAsync(ms, f) count("LoopAsync"); off_thread("off-thread-api", "LoopAsync(" .. tostring(ms) .. ")", where()); add_timer("async", ms, f, true) end
function ExecuteWithDelay(ms, f) count("ExecuteWithDelay"); off_thread("off-thread-api", "ExecuteWithDelay(" .. tostring(ms) .. ")", where()); add_timer("async", ms, f, false) end
function ExecuteAsync(f) count("ExecuteAsync"); off_thread("off-thread-api", "ExecuteAsync()", where()); add_timer("async", 0, f, false) end

-- The UE4SS "InGameThread" family (newer builds; f08dfdf lacks it). Arguments are read loosely: the first number is the delay
-- (ms) or frame count, the first function is the callback (some builds put a handle first).
local function delay_and_fn(a, b, c)
    local n, f
    for _, v in ipairs({ a, b, c }) do
        if n == nil and type(v) == "number" then n = v end
        if f == nil and type(v) == "function" then f = v end
    end
    return n or 0, f
end

local function game_timer(name, in_frames, loop, retrigger)
    return function(a, b, c)
        count(name)
        local at = where()
        off_thread("off-thread-api", name .. "()", at)   -- none of these are used by the safe pattern, in any game
        local n, f = delay_and_fn(a, b, c)
        if not f then error(name .. ": callback must be a function", 2) end
        local ms = in_frames and n * H.config.tick_ms or n
        if retrigger then   -- re-arming from the same call site replaces the pending timer
            for _, t in ipairs(H.timers) do if t.retrig == at and not t.dead then t.dead = true end end
        end
        local t = add_timer("game", ms, f, loop)
        if retrigger then t.retrig = at end
        return t
    end
end

local function install_optional_api()
    -- Under forbid_off_thread the whole family exists (newer UE4SS builds have it), so a call is reported instead of silently
    -- skipped by a mod's `if LoopInGameThreadWithDelay then` feature check.
    if H.config.has_loop_in_game_thread or H.config.forbid_off_thread then
        LoopInGameThreadWithDelay = game_timer("LoopInGameThreadWithDelay", false, true)
        ExecuteInGameThreadWithDelay = game_timer("ExecuteInGameThreadWithDelay", false, false)
        RetriggerableExecuteInGameThreadWithDelay = game_timer("RetriggerableExecuteInGameThreadWithDelay", false, false, true)
        ExecuteInGameThreadAfterFrames = game_timer("ExecuteInGameThreadAfterFrames", true, false)
        LoopInGameThreadAfterFrames = game_timer("LoopInGameThreadAfterFrames", true, true)
    else
        LoopInGameThreadWithDelay = nil
        ExecuteInGameThreadWithDelay = nil
        RetriggerableExecuteInGameThreadWithDelay = nil
        ExecuteInGameThreadAfterFrames = nil
        LoopInGameThreadAfterFrames = nil
    end
end

function FindFirstOf(cls)
    api_touch("FindFirstOf", cls)
    for _, p in ipairs(H.by_class[cls] or {}) do if D[p].valid then return p end end
    return H.invalid
end
function FindAllOf(cls)
    api_touch("FindAllOf", cls)
    local out = {}
    for _, p in ipairs(H.by_class[cls] or {}) do if D[p].valid then out[#out + 1] = p end end
    if #out == 0 then return nil end
    return out
end
function StaticFindObject(path)
    api_touch("StaticFindObject", path)
    local p = H.statics[path]
    if p and D[p].valid then return p end
    return H.invalid
end
function StaticConstructObject(cls, outer, ...)
    api_touch("StaticConstructObject", cls)
    if H.on_construct then return H.on_construct(cls, outer, ...) end
    local cname = (cls and D[cls]) and D[cls].name or "Constructed"
    return H.obj(cname .. "_new", {}, { class = cls, outer = outer })
end

-- UE4SS "special" hooks (engine events)
local function special(name) return function(cb) count(name); H.special[name] = H.special[name] or {}; table.insert(H.special[name], cb) end end
for _, n in ipairs({ "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook", "RegisterBeginPlayPreHook",
                     "RegisterBeginPlayPostHook", "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
                     "RegisterProcessConsoleExecPreHook", "RegisterProcessConsoleExecPostHook" }) do
    _G[n] = special(n)
end
function RegisterConsoleCommandHandler(name, cb) count("RegisterConsoleCommandHandler"); H.console_handlers[name:lower()] = cb end
function RegisterConsoleCommandGlobalHandler(name, cb) count("RegisterConsoleCommandGlobalHandler"); H.console_handlers[name:lower()] = cb end

-- Default UEHelpers (scenarios can replace package.loaded["UEHelpers"])
local function default_uehelpers()
    return {
        GetPlayerController = function()
            count("UEHelpers.GetPlayerController")
            if H.player_controller and D[H.player_controller].valid then touch(D[H.player_controller], "UEHelpers.GetPlayerController()") return H.player_controller end
            return FindFirstOf("PlayerController")
        end,
        GetPlayer = function()
            local pc = package.loaded["UEHelpers"].GetPlayerController()
            if pc and pc:IsValid() then return pc.Pawn end
            return H.invalid
        end,
        GetWorld = function() api_touch("UEHelpers.GetWorld"); return H.world or H.invalid end,
        GetEngine = function() return FindFirstOf("Engine") end,
        GetGameViewportClient = function() return FindFirstOf("GameViewportClient") end,
        GetKismetSystemLibrary = function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end,
        GetKismetMathLibrary = function() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end,
        GetGameplayStatics = function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end,
    }
end

-- ------------------------------------------------------------------ simulated engine
--- Fire a UFunction hook as the game would (game thread). Args are wrapped as params automatically.
--- H.hook_impl[path] = function(self, ...) can simulate the native function body between pre and post.
function H.fire_hook(path, self_obj, ...)
    local args = table.pack(...)
    local wrapped = {}
    for i = 1, args.n do wrapped[i] = is_param(args[i]) and args[i] or H.param(args[i]) end
    local ctx = is_param(self_obj) and self_obj or H.param(self_obj)
    local list = H.hooks[path] or {}
    for _, h in ipairs(list) do on_thread("game", "hook pre " .. path, h.pre, ctx, unpack(wrapped, 1, args.n)) end
    local ret
    if H.hook_impl[path] then ret = on_thread("game", "native " .. path, H.hook_impl[path], self_obj, ...) end
    for _, h in ipairs(list) do if h.post then on_thread("game", "hook post " .. path, h.post, ctx, unpack(wrapped, 1, args.n)) end end
    return ret, #list
end

function H.fire_special(name, ...)
    for _, cb in ipairs(H.special[name] or {}) do on_thread("game", name, cb, ...) end
end

--- Simulate a new object being spawned: fires NotifyOnNewObject callbacks matching its class chain.
function H.spawn(p)
    local names = {}
    for _, n in ipairs(class_names(D[p].class)) do names[n] = true end
    for _, n in ipairs(H.notify) do if names[n.cls] then on_thread("game", "NotifyOnNewObject " .. n.cls, n.cb, p) end end
    return p
end

--- Press a key: runs matching RegisterKeyBind callbacks (thread per H.config.keybind_thread; Async ones on "async").
function H.press(key, mods)
    mods = mods or {}
    local n = 0
    for _, k in ipairs(H.keybinds) do
        local match = k.key == key and #k.mods == #mods
        if match then for i, m in ipairs(k.mods) do if mods[i] ~= m then match = false end end end
        if match then
            n = n + 1
            local thread = k.async and "async" or H.config.keybind_thread
            on_thread(thread, "keybind " .. tostring(key), k.cb)
        end
    end
    return n
end

--- Hold (down = true) or release a key for PlayerController:IsInputKeyDown / WasInputKeyJustPressed.
--- name = the Unreal FKey name ("NumPadFour", "Divide", "Add", "F11", ...). The game-thread read happens whenever
--- the mod polls (e.g. from a per-frame hook the scenario fires); nothing runs on another thread.
function H.key_down(name, down)
    if down and not H.keys[name] then H.key_pressed_frame[name] = H.frame end
    H.keys[name] = down and true or nil
end

--- Simulate a console command (fires ExecuteConsoleCommand hooks and console handlers).
function H.console(cmd)
    local kismet = H.statics["/Script/Engine.Default__KismetSystemLibrary"]
    H.fire_hook("/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand", kismet, H.world, FString(cmd), H.player_controller)
    local name = cmd:match("^%s*(%S+)")
    local h = name and H.console_handlers[name:lower()]
    if h then on_thread("game", "console " .. name, h, cmd, {}, nil) end
end

--- Scenario hook: fn(H) runs on the game thread every frame, before the ExecuteInGameThread queue.
function H.on_frame(fn) H.frame_fns[#H.frame_fns + 1] = fn end

--[[ The game calls a UFunction every frame on the game thread (a HUD's update function, a character's tick
  function: pick one from your reflection dump). Hook-driven mods do all their work in such a hook.
  self_obj is an object, or a function returning the current object (so it follows world changes; return nil
  for "nothing ticks right now", e.g. the main menu). Extra arguments are passed to the hook as parameters.
  Fires every frame on the game thread until the world is torn down after quit, like a destroyed actor.
]]
function H.every_frame_hook(path, self_obj, ...)
    local extra = table.pack(...)
    H.on_frame(function()
        if H.quit_state == "torn_down" then return end
        local obj = self_obj
        if type(self_obj) == "function" then obj = self_obj(H) end
        if obj == nil or not H.is_alive(obj) then return end
        H.fire_hook(path, obj, unpack(extra, 1, extra.n))
    end)
end

local function teardown()
    H.quit_state = "torn_down"
    for _, p in ipairs(H.all_objects) do if not D[p].persistent then D[p].valid = false end end
    H.alive_at_teardown = {}
    for _, t in ipairs(H.timers) do if not t.dead then H.alive_at_teardown[#H.alive_at_teardown + 1] = t end end
    H.queued_at_teardown = #H.gt_queue
end

--- Advance n frames. Each frame: background timers/loops, then game-thread work (frame fns, queue, game loops).
function H.tick(n)
    for _ = 1, (n or 1) do
        if H.quit_state == "killed" then return end
        H.now = H.now + H.config.tick_ms / 1000
        H.frame = H.frame + 1
        -- background thread
        for _, t in ipairs(H.timers) do
            if t.kind == "async" and not t.dead and H.now + 1e-9 >= t.at then
                local r = on_thread("async", (t.loop and "LoopAsync" or "delayed callback") .. " (" .. t.where .. ")", t.f)
                if t.loop and r ~= true then t.at = H.now + t.ms / 1000 else t.dead = true end
            end
        end
        -- game thread
        for _, fn in ipairs(H.frame_fns) do on_thread("game", "scenario frame", fn, H) end
        if H.config.executor_alive then
            local q = H.gt_queue
            H.gt_queue = {}
            for _, item in ipairs(q) do on_thread("game", "ExecuteInGameThread (" .. item.where .. ")", item.f) end
            for _, t in ipairs(H.timers) do
                if t.kind == "game" and not t.dead and H.now + 1e-9 >= t.at then
                    local r = on_thread("game", "game-thread timer (" .. t.where .. ")", t.f)
                    if t.loop and r ~= true then t.at = H.now + t.ms / 1000 else t.dead = true end
                end
            end
        end
        -- quit / teardown progression
        if H.quit_state == "quitting" then
            H.quit_frames = H.quit_frames + 1
            if H.quit_frames >= H.config.teardown_ticks then teardown() end
        end
    end
end

--- Advance simulated time in seconds.
function H.run(seconds) H.tick(math.max(1, math.floor(seconds * 1000 / H.config.tick_ms + 0.5))) end

--[[ World change (level travel / load / return to menu).
  Invalidates every non-persistent object, bumps H.world_gen, then calls builder() (on the test thread) to
  create the new world's objects, then fires LoadMap post hooks. Old references held by the mod become invalid,
  exactly like dangling pointers would - a mod that doesn't re-check IsValid() will error here.
]]
function H.change_world(builder)
    H.fire_special("RegisterLoadMapPreHook")
    for _, p in ipairs(H.all_objects) do if not D[p].persistent then D[p].valid = false end end
    H.world_gen = H.world_gen + 1
    H.world, H.player_controller = nil, nil
    for k, list in pairs(H.by_class) do
        local keep = {}
        for _, p in ipairs(list) do if D[p].valid then keep[#keep + 1] = p end end
        H.by_class[k] = keep
    end
    local r
    if builder then r = builder(H) end
    H.fire_special("RegisterLoadMapPostHook", H.world)
    return r
end

--[[ Quit.
  via = "menu"    (default) fires /Script/Engine.KismetSystemLibrary:QuitGame on the game thread, then after
                  H.config.teardown_ticks frames the world is torn down (all non-persistent objects invalid).
  via = "console" fires the ExecuteConsoleCommand hook with "quit", then the same teardown.
  via = "kill"    force-close (like stopping the game from the launcher): no hooks, nothing more runs.
                  Crash files from a force-close are not real crashes - test with via="menu".
]]
function H.quit(via)
    via = via or "menu"
    if via == "kill" then H.quit_state = "killed" return end
    if via == "console" then H.console("quit")
    else H.fire_hook("/Script/Engine.KismetSystemLibrary:QuitGame", H.statics["/Script/Engine.Default__KismetSystemLibrary"], H.world, H.player_controller, 0, false) end
    H.quit_state = "quitting"
    H.quit_frames = 0
end

--- After H.quit(): run to teardown and past it, then report what was still running.
function H.quit_report(extra_seconds)
    H.run(extra_seconds or 1.0)
    local alive = {}
    for _, t in ipairs(H.timers) do if not t.dead then alive[#alive + 1] = (t.loop and "loop" or "timer") .. " from " .. t.where end end
    local after = 0
    for _, v in ipairs(H.violations) do if v.kind == "after-teardown" then after = after + v.count end end
    return { alive = alive, scheduled_after_quit = H.scheduled_after_quit, access_after_teardown = after, queued = #H.gt_queue }
end

-- ------------------------------------------------------------------ test world builder
--[[ H.player_world(opts) -> w
  Builds a typical single-player world: w.world, w.gm (game mode), w.pc (player controller), w.pawn.
  opts.pawn_fields / opts.pc_fields / opts.gm_fields add members. Registers classes PlayerController, Pawn,
  Character, GameModeBase, World so FindFirstOf("PlayerController") etc. work. Sets H.world / H.player_controller.
]]
function H.player_world(opts)
    opts = opts or {}
    local gen = H.world_gen
    H.class("Actor", nil, "/Script/Engine.Actor")
    H.class("Pawn", "Actor", "/Script/Engine.Pawn")
    H.class("Character", "Pawn", "/Script/Engine.Character")
    H.class("Controller", "Actor", "/Script/Engine.Controller")
    H.class("PlayerController", "Controller", "/Script/Engine.PlayerController")
    H.class("GameModeBase", "Actor", "/Script/Engine.GameModeBase")
    H.class("World", nil, "/Script/Engine.World")
    local w = {}
    local function merge(base, extra) for k, v in pairs(extra or {}) do base[k] = v end return base end
    w.gm = H.obj("GameMode_" .. gen, merge({ bActorIsBeingDestroyed = false }, opts.gm_fields), { class = H.class(opts.gm_class or "GameMode_C", "GameModeBase") })
    w.world = H.obj("World_" .. gen, merge({ AuthorityGameMode = w.gm }, opts.world_fields), { class = "World" })
    w.pawn = H.obj("PlayerCharacter_C_" .. gen, merge({ bActorIsBeingDestroyed = false }, opts.pawn_fields), { class = H.class(opts.pawn_class or "PlayerCharacter_C", "Character") })
    w.pc = H.obj("PlayerController_C_" .. gen, merge({ Pawn = w.pawn, bActorIsBeingDestroyed = false,
        GetWorld = function() return H.world or H.invalid end,
        IsLocalController = function() return true end,
        IsLocalPlayerController = function() return true end }, opts.pc_fields),
        { class = H.class(opts.pc_class or "PlayerController_C", "PlayerController") })
    H.world, H.player_controller = w.world, w.pc
    return w
end

-- ------------------------------------------------------------------ assertions and log helpers
function H.check(cond, msg)
    H.results[#H.results + 1] = { ok = cond and true or false, msg = msg }
    return cond
end
function H.eq(actual, expected, msg)
    return H.check(actual == expected, string.format("%s (expected %s, got %s)", msg, tostring(expected), tostring(actual)))
end
function H.log_count(pattern, plain)
    local c = 0
    for _, l in ipairs(H.log) do if l:find(pattern, 1, plain ~= false) then c = c + 1 end end
    return c
end
function H.mark() return #H.log end
function H.log_count_since(mark, pattern)
    local c = 0
    for i = mark + 1, #H.log do if H.log[i]:find(pattern, 1, true) then c = c + 1 end end
    return c
end
function H.dump_log(from, to)
    for i = math.max(1, from or 1), math.min(#H.log, to or #H.log) do io.write("      | ", H.log[i], "\n") end
end
function H.async_violations()
    local n = 0
    for _, v in ipairs(H.violations) do if v.kind == "background-thread" then n = n + v.count end end
    return n
end

-- ------------------------------------------------------------------ reset / load
local STD = { _G = true, package = true, coroutine = true, table = true, io = true, os = true, string = true,
              math = true, utf8 = true, debug = true }

function H.reset()
    H.config = default_config()
    H.now, H.frame, H.thread = 0, 0, "test"
    H.log, H.errors, H.violations, H.warnings, H.results = {}, {}, {}, {}, {}
    H._viol_seen, H._warn_seen = {}, {}
    H.accesses = setmetatable({}, { __index = function() return 0 end })   -- "Obj.Field" -> count (all threads)
    H.touches, H.calls = {}, setmetatable({}, { __index = function() return 0 end })
    H.hooks, H.hook_impl, H.missing_hooks, H.known_hooks = {}, {}, {}, nil
    H.hook_id = 0
    H.notify, H.keybinds, H.special, H.console_handlers = {}, {}, {}, {}
    H.keys, H.key_pressed_frame, H.key_reads = {}, {}, {}
    H.timers, H.gt_queue, H.max_queue, H.frame_fns = {}, {}, 0, {}
    H.all_objects, H.by_class, H.statics, H.classes = {}, {}, {}, {}
    H.world_gen, H.world, H.player_controller = 1, nil, nil
    H.quit_state, H.quit_frames, H.scheduled_after_quit = nil, 0, 0
    H.on_write, H.on_construct = nil, nil
    H.invalid = new_proxy({ name = "InvalidObject", path = "", fields = {}, valid = false, persistent = true })
    D[H.invalid].valid = false
    H.statics["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("Default__KismetSystemLibrary", {}, { persistent = true, find = false })
    H.statics["/Script/Engine.Default__GameplayStatics"] = H.obj("Default__GameplayStatics", {}, { persistent = true, find = false })
    for k in pairs(package.loaded) do if not STD[k] then package.loaded[k] = nil end end
    package.loaded["UEHelpers"] = default_uehelpers()
    os.clock = function() return H.now end
    local real_time = H._real_time or os.time
    H._real_time = real_time
    os.time = function(t) if t then return real_time(t) end return 1700000000 + math.floor(H.now) end
    setmetatable(_G, nil)
end

--- Load and run a mod's main.lua (as UE4SS does at startup). Returns true if it loaded without error.
function H.load_mod(main_path)
    main_path = main_path or H.mod_main
    H.mod_main = main_path
    local norm = main_path:gsub("\\", "/")
    H.mod_dir = norm:match("^(.*)/[^/]*$") or "."
    package.path = H.mod_dir .. "/?.lua;" .. H.mod_dir .. "/?/init.lua;" .. (H._base_path or package.path)
    H._base_path = H._base_path or package.path
    install_optional_api()
    local chunk, err = loadfile(main_path)
    if not chunk then record_error("compile " .. main_path, err) return false end
    if H.config.warn_undefined_globals then
        setmetatable(_G, { __index = function(_, k)
            if mod_frame() then
                H.warn(string.format("mod reads global '%s' that was never set (%s) - a local declared later, a typo, or an API missing in this UE4SS build?", tostring(k), where()), "global|" .. tostring(k))
            end
            return nil
        end })
    end
    local before = #H.errors
    on_thread("load", "main.lua", chunk)
    return #H.errors == before
end

H.reset()
return H
