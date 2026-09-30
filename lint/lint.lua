--[[
lint.lua - static checks for UE4SS Lua mods (no game needed). Complements the offline harness.
SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software

Usage:
  lua lint/lint.lua <path> [<path> ...] [--strict] [--quiet] [--warn-threading]
    <path>    a mod folder (contains Scripts/main.lua), a folder holding several mods, or a single .lua file
    --strict  WARN findings also make the exit code 1 (use in CI once your mods are clean)
    --quiet   print only mods with findings
    --warn-threading  report the threading APIs below as WARN instead of ERROR (for a mod you are still migrating)

Checks per Scripts/*.lua file:
  ERROR  does not compile (syntax error)
  WARN   global READ but never SET anywhere in the mod and not a known Lua/UE4SS global
         (a local declared after the function that reads it, a typo, or an API missing in your UE4SS build).
         Needs `luac` (Lua 5.4) on PATH; skipped with a note if it is missing.
  ERROR  threading API: RegisterKeyBind, RegisterKeyBindAsync, LoopAsync, ExecuteAsync, ExecuteWithDelay,
         ExecuteInGameThread and the InGameThread delayed family (ExecuteInGameThreadWithDelay, LoopInGameThreadWithDelay,
         RetriggerableExecuteInGameThreadWithDelay, ExecuteInGameThreadAfterFrames, LoopInGameThreadAfterFrames).
         They run Lua on UE4SS threads, or drain a queue from whatever thread fires ProcessEvent, and a mod has one
         Lua state that its game-thread hooks share: crashes follow. Do the work inside a hook on a UFunction the game
         calls on its game thread, and read keys there with PlayerController:IsInputKeyDown (see lib/otc_keys.lua).
  WARN   `if x then` right after `local x = FindFirstOf/StaticFindObject(...)` without IsValid()
         (these return an invalid object, not nil, when nothing is found)
  WARN   type(obj.Fn) == "function" (game UFunctions are userdata, so this is always false)
  INFO   RegisterInitGameState* / RegisterBeginPlay* (mis-resolved on some builds; prefer RegisterHook on a
         verified UFunction path)
  The shared helper files otc_safe.lua, otc_selfcheck.lua and otc_keys.lua are compile-checked only (otc_safe's
  queue helpers are opt-in, off by default, and reported by the harness when a mod turns them on).

Exit code: 1 if any ERROR (or any WARN with --strict), else 0.
]]

local sep = package.config:sub(1, 1)
local WIN = sep == "\\"

local KNOWN = {}
for w in ([[
_G _ENV _VERSION assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print rawequal
rawget rawlen rawset require select setmetatable tonumber tostring type xpcall warn coroutine debug io math os package
string table utf8 arg
RegisterHook UnregisterHook NotifyOnNewObject FindFirstOf FindAllOf FindObject FindObjects StaticFindObject
StaticConstructObject ForEachUObject CreateInvalidObject LoadAsset RegisterKeyBind RegisterKeyBindAsync
IsKeyBindRegistered Key ModifierKey ExecuteInGameThread ExecuteWithDelay ExecuteAsync LoopAsync LoopInGameThread
LoopInGameThreadWithDelay ExecuteInGameThreadWithDelay RegisterCustomEvent UnregisterCustomEvent
RegisterConsoleCommandHandler RegisterConsoleCommandGlobalHandler RegisterProcessConsoleExecPreHook
RegisterProcessConsoleExecPostHook RegisterCallFunctionByNameWithArgumentsPreHook
RegisterCallFunctionByNameWithArgumentsPostHook RegisterULocalPlayerExecPreHook RegisterULocalPlayerExecPostHook
RegisterInitGameStatePreHook RegisterInitGameStatePostHook RegisterBeginPlayPreHook RegisterBeginPlayPostHook
RegisterLoadMapPreHook RegisterLoadMapPostHook RegisterEndPlayPreHook RegisterEndPlayPostHook
FName FText FString EFindName EObjectFlags EInternalObjectFlags PropertyTypes ModRef UE4SS IterateGameDirectories
DumpAllObjects GenerateSDK GenerateUHTCompatibleHeaders DumpStaticMeshes DumpAllActors DumpUSMAP Unreal UEHelpers
FPackageName RegisterLocalPlayerExecPreHook
]]):gmatch("%S+") do KNOWN[w] = true end

-- Methods UE4SS provides on its wrapper objects: type(obj.<these>) == "function" is a valid feature check.
local UE4SS_METHODS = {}
for w in ([[get set type GetFullName GetName GetFName IsValid IsA GetClass GetOuter GetWorld GetAddress ForEach
GetArrayNum GetArrayMax Empty ToString GetPropertyValue SetPropertyValue Reflection GetFunctionFlags SetFunctionFlags
HasAnyInternalFlags IsClass GetCDO IsAnyClass GetSuperStruct ForEachFunction ForEachProperty GetValueFromArray
CallFunction ToTable GetPlainName GetComparisonIndex]]):gmatch("%S+") do UE4SS_METHODS[w] = true end

local THREADING = { "RegisterKeyBind", "RegisterKeyBindAsync", "LoopAsync", "ExecuteAsync", "ExecuteWithDelay",
                    "ExecuteInGameThread", "ExecuteInGameThreadWithDelay", "LoopInGameThreadWithDelay",
                    "RetriggerableExecuteInGameThreadWithDelay", "ExecuteInGameThreadAfterFrames", "LoopInGameThreadAfterFrames" }
local INFO_API = { "RegisterInitGameState%w*", "RegisterBeginPlay%w*" }
local LIBRARY_FILES = { ["otc_safe.lua"] = true, ["otc_selfcheck.lua"] = true, ["otc_keys.lua"] = true }

-- ------------------------------------------------------------------ args
local paths, strict, quiet, warn_threading = {}, false, false, false
for _, a in ipairs(arg) do
    if a == "--strict" then strict = true
    elseif a == "--quiet" then quiet = true
    elseif a == "--warn-threading" then warn_threading = true
    elseif a == "-h" or a == "--help" then io.write("usage: lua lint.lua <mod folder | mods folder | file.lua> [...] [--strict] [--quiet] [--warn-threading]\n") os.exit(0)
    else paths[#paths + 1] = a end
end
if #paths == 0 then io.write("usage: lua lint.lua <mod folder | mods folder | file.lua> [...] [--strict] [--quiet] [--warn-threading]\n") os.exit(2) end

-- ------------------------------------------------------------------ helpers
local function shell_lines(cmd)
    local out = {}
    local ok, p = pcall(io.popen, cmd)
    if not ok or not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end
local function q(s) return '"' .. s .. '"' end
local function norm(s) return (s:gsub("[/\\]", sep)) end
local function is_dir(p)
    if WIN then return #shell_lines('if exist ' .. q(norm(p) .. "\\*") .. ' echo d') > 0 end
    return #shell_lines('[ -d ' .. q(p) .. ' ] && echo d') > 0
end
local function all_lua(dir)
    if WIN then return shell_lines('dir /b /s /a-d ' .. q(norm(dir) .. "\\*.lua") .. ' 2>nul') end
    return shell_lines('find ' .. q(dir) .. ' -type f -name "*.lua" 2>/dev/null | sort')
end
local function basename(p) return p:match("[^/\\]+$") or p end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close() return s end

local LUAC
for _, c in ipairs({ "luac5.4", "luac54", "luac" }) do
    local out = shell_lines(c .. " -v" .. (WIN and " 2>nul" or " 2>/dev/null"))
    if out[1] and out[1]:find("5%.4") then LUAC = c break end
end

-- group files into mods: files under .../<Mod>/Scripts/ belong to <Mod>; a single file is its own group
local mods, order = {}, {}
local function add(modname, file)
    if not mods[modname] then mods[modname] = {}; order[#order + 1] = modname end
    table.insert(mods[modname], file)
end
for _, p in ipairs(paths) do
    if is_dir(p) then
        for _, f in ipairs(all_lua(p)) do
            local unix = f:gsub("\\", "/")
            local mod = unix:match("([^/]+)/[Ss]cripts/[^/]+$") or unix:match("([^/]+)/[Ss]cripts/.+/[^/]+$")
            if mod then add(mod, f) end
        end
    else
        add(basename(p), p)
    end
end

-- ------------------------------------------------------------------ checks
local n_err, n_warn = 0, 0
for _, mod in ipairs(order) do
    local findings = {}
    local function F(level, msg) findings[#findings + 1] = level .. " " .. msg end
    local sets, reads, texts = {}, {}, {}
    for _, file in ipairs(mods[mod]) do
        local name = basename(file)
        local src = read(file) or ""
        local chunk, cerr = load(src, "@" .. name)
        if not chunk then
            F("ERROR", "syntax: " .. tostring(cerr))
        elseif not LIBRARY_FILES[name] then
            texts[#texts + 1] = src
            if LUAC then
                for _, l in ipairs(shell_lines(LUAC .. " -l -l -p " .. q(file) .. (WIN and " 2>nul" or " 2>/dev/null"))) do
                    local op, g = l:match("([GS]ET)TABUP.*;%s*_ENV%s+\"([^\"]+)\"")
                    if op == "SET" then sets[g] = true elseif op == "GET" and not reads[g] then reads[g] = name end
                end
            end
            local lines = {}
            for ln in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = ln:gsub("\r$", "") end
            for i, ln in ipairs(lines) do
                local code = ln:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")   -- blank out simple string literals
                code = code:gsub("%-%-.*$", "")                                -- drop line comments
                if code:match("%S") then
                    -- any reference counts: LoopAsync(...), pcall(ExecuteInGameThread, f), local E = ExecuteWithDelay
                    for _, api in ipairs(THREADING) do
                        if code:find("%f[%w_]" .. api .. "%f[^%w_]") then
                            F(warn_threading and "WARN" or "ERROR", string.format("%s:%d uses %s - runs Lua off the game thread (crash risk); do the work inside a game-thread hook instead", name, i, api))
                        end
                    end
                    for _, api in ipairs(INFO_API) do
                        local hit = code:match("%f[%w_](" .. api .. ")%f[^%w_]")
                        if hit then
                            F("INFO", string.format("%s:%d uses %s", name, i, hit))
                        end
                    end
                    local v = code:match("local%s+([%w_]+)%s*=%s*[%w_%.]*FindFirstOf%f[^%w_]") or code:match("local%s+([%w_]+)%s*=%s*[%w_%.]*StaticFindObject%f[^%w_]")
                    if v then
                        for j = i + 1, math.min(i + 3, #lines) do
                            local nxt = lines[j]
                            if (nxt:find("if%s+" .. v .. "%s+then") or nxt:find("if%s+not%s+" .. v .. "%s+then")) and not nxt:find("IsValid") then
                                F("WARN", string.format("%s:%d '%s' - FindFirstOf/StaticFindObject return an invalid object, not nil; use %s and %s:IsValid()", name, j, nxt:match("^%s*(.-)%s*$"), v, v))
                            end
                        end
                    end
                    local raw = ln:gsub("%-%-.*$", "")                        -- keeps string literals
                    for obj, meth in raw:gmatch("type%s*%(%s*([%w_]+)[%.:]([%w_]+)%s*%)%s*==%s*[\"']function[\"']") do
                        if not UE4SS_METHODS[meth] and not KNOWN[obj] and not raw:find("type%s*%(%s*" .. obj .. "%s*%)%s*==%s*\"table\"")
                           and obj ~= "self" and obj ~= "M" and obj ~= "S" and obj ~= "Safe" and obj ~= "config" and obj ~= "cfg" then
                            F("WARN", string.format("%s:%d type(%s.%s) == \"function\": if %s is a game UFunction this is always false (userdata)", name, i, obj, meth, meth))
                        end
                    end
                end
            end
        end
    end
    if LUAC then
        local all = table.concat(texts, "\n")
        local unknown = {}
        for g, file in pairs(reads) do
            local esc = g:gsub("%W", "%%%0")
            if not sets[g] and not KNOWN[g]
               and not all:find("type%s*%(%s*" .. esc .. "%s*%)") and not all:find("%f[%w_]or%s+" .. esc .. "%f[^%w_]")
               and not all:find("%f[%w_]" .. esc .. "%s+or%f[^%w_]") then
                unknown[#unknown + 1] = { g = g, file = file }
            end
        end
        table.sort(unknown, function(a, b) return a.g < b.g end)
        for _, u in ipairs(unknown) do
            F("WARN", string.format("global '%s' is read but never set (%s) - declared later as a local, a typo, or an API missing in your UE4SS build?", u.g, u.file))
        end
    end
    local worst = "ok"
    for _, f in ipairs(findings) do
        if f:find("^ERROR") then worst = "ERROR"; n_err = n_err + 1
        elseif f:find("^WARN") then if worst ~= "ERROR" then worst = "WARN" end; n_warn = n_warn + 1 end
    end
    if not (quiet and worst == "ok") then
        io.write(string.format("[%-5s] %s\n", worst, mod))
        for _, f in ipairs(findings) do io.write("        " .. f .. "\n") end
    end
end

if not LUAC then io.write("note: luac (Lua 5.4) not found on PATH - the never-set-globals check was skipped\n") end
io.write(string.format("lint: %d mod(s), %d error(s), %d warning(s)\n", #order, n_err, n_warn))
os.exit(((n_err > 0) or (strict and n_warn > 0)) and 1 or 0)
