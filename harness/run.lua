--[[
run.lua - offline test runner for UE4SS Lua mods.

Usage (from any folder):
  lua run.lua <path\to\Mod\Scripts\main.lua> <scenarios.lua> [more_scenarios.lua ...]

Prints PASS/FAIL per scenario and exits 0 only if every scenario passed.

A scenario file returns:
  return {
    setup = function(H) ... end,          -- optional: build the fake world before the mod loads (every scenario)
    scenarios = {
      { name = "normal play", run = function(H) ... end },
      { name = "...", setup = function(H) ... end, run = function(H) ... end,
        allow_errors = false,               -- true if Lua errors in mod callbacks are expected
        no_autoload = false },              -- true to call H.load_mod() yourself inside run
    },
  }

Checks added automatically to every scenario (a scenario fails if any is violated):
  * main.lua and every .lua next to it compiles
  * no UObject access from the simulated background thread (LoopAsync / ExecuteWithDelay / async keybinds)
  * no UObject access after world teardown (quit)
  * no uncaught Lua errors inside mod callbacks (unless allow_errors)
  * with H.config.forbid_off_thread (or env HARNESS_FORBID_OFF_THREAD=1): nothing
    registered with RegisterKeyBind / RegisterKeyBindAsync / LoopAsync / ExecuteAsync / ExecuteWithDelay /
    ExecuteInGameThread / ExecuteInGameThreadWithDelay / LoopInGameThreadWithDelay / RetriggerableExecuteInGameThreadWithDelay /
    ExecuteInGameThreadAfterFrames / LoopInGameThreadAfterFrames and no callback run on the "async" or "input" thread

SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
]]

local sep = package.config:sub(1, 1)
local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local H = dofile(here .. sep .. "fake_ue4ss.lua")

local out = io.write
local main_path = arg[1]
local scen_paths = {}
for i = 2, #arg do scen_paths[#scen_paths + 1] = arg[i] end
if not main_path or #scen_paths == 0 then
    out("usage: lua run.lua <Mod\\Scripts\\main.lua> <scenarios.lua> [...]\n")
    os.exit(2)
end

-- 1. compile check of every .lua in the mod's Scripts folder
local function list_lua(dir)
    local cmd
    if sep == "\\" then cmd = 'dir /b "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul'
    else cmd = 'ls -1 "' .. dir .. '" 2>/dev/null' end
    local files = {}
    local ok, p = pcall(io.popen, cmd)
    if ok and p then
        for line in p:lines() do if line:match("%.lua$") then files[#files + 1] = line end end
        p:close()
    end
    return files
end

local total_fail = 0
local mod_dir = main_path:match("^(.*)[/\\][^/\\]*$") or "."
out(string.format("UE4SS offline harness\n  mod:  %s\n", main_path))
local compile_ok = true
local files = list_lua(mod_dir)
if #files == 0 then files = { main_path:match("[^/\\]+$") } end
for _, f in ipairs(files) do
    local fn, err = loadfile(mod_dir .. sep .. f)
    if not fn then compile_ok = false; out("  COMPILE FAIL " .. f .. ": " .. tostring(err) .. "\n") end
end
if not compile_ok then out("RESULT: FAIL (does not compile)\n"); os.exit(1) end
out(string.format("  compile: OK (%d file(s))\n", #files))

-- 2. scenarios
local function load_scenarios(path)
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load scenario file " .. path .. ": " .. tostring(err)) end
    local spec = chunk()
    if type(spec) ~= "table" then error(path .. " must return a table") end
    if spec.scenarios == nil and spec[1] then spec = { scenarios = spec } end
    return spec
end

local passed, failed = 0, 0
for _, sp in ipairs(scen_paths) do
    local spec = load_scenarios(sp)
    out(string.format("  scenarios: %s (%d)\n", sp, #spec.scenarios))
    for idx, sc in ipairs(spec.scenarios) do
        H.reset()
        local name = sc.name or ("scenario " .. idx)
        local run_ok, run_err = xpcall(function()
            if spec.setup then spec.setup(H) end
            if sc.setup then sc.setup(H) end
            if not sc.no_autoload then H.load_mod(main_path) end
            H.thread = "test"
            if sc.run then sc.run(H) end
        end, debug.traceback)
        H.thread = "test"
        setmetatable(_G, nil)

        -- automatic checks
        local auto = {}
        local async_n, teardown_n, off_n = 0, 0, 0
        for _, v in ipairs(H.violations) do
            if v.kind == "after-teardown" then teardown_n = teardown_n + v.count
            elseif v.kind == "off-thread-api" or v.kind == "off-thread-callback" then off_n = off_n + v.count
            else async_n = async_n + v.count end
        end
        auto[#auto + 1] = { ok = async_n == 0, msg = "no UObject access from a background thread" .. (async_n > 0 and (" (" .. async_n .. " accesses)") or "") }
        if H.config.forbid_off_thread then
            auto[#auto + 1] = { ok = off_n == 0, msg = "no Lua registered or run off the game thread (RegisterKeyBind/RegisterKeyBindAsync/LoopAsync/ExecuteAsync/ExecuteWithDelay/ExecuteInGameThread/*InGameThread*WithDelay/*InGameThreadAfterFrames forbidden)" .. (off_n > 0 and (" (" .. off_n .. ")") or "") }
        end
        auto[#auto + 1] = { ok = teardown_n == 0, msg = "no UObject access after world teardown" .. (teardown_n > 0 and (" (" .. teardown_n .. ")") or "") }
        if not sc.allow_errors then
            auto[#auto + 1] = { ok = #H.errors == 0, msg = "no Lua errors in mod code" .. (#H.errors > 0 and (" (" .. #H.errors .. ")") or "") }
        end
        if not run_ok then auto[#auto + 1] = { ok = false, msg = "scenario script error: " .. tostring(run_err) } end

        local bad = {}
        for _, r in ipairs(H.results) do if not r.ok then bad[#bad + 1] = r.msg end end
        for _, r in ipairs(auto) do if not r.ok then bad[#bad + 1] = r.msg end end
        local nchecks = #H.results + #auto
        if #bad == 0 then
            passed = passed + 1
            out(string.format("PASS  %s  (%d checks)\n", name, nchecks))
        else
            failed = failed + 1
            out(string.format("FAIL  %s  (%d of %d checks failed)\n", name, #bad, nchecks))
            for _, m in ipairs(bad) do out("        x " .. m .. "\n") end
            local shown = 0
            for _, v in ipairs(H.violations) do
                if shown < 8 then
                    out(string.format("        ! %s: %s at %s (x%d)\n", v.kind, v.what, v.where, v.count))
                    shown = shown + 1
                end
            end
            for i, e in ipairs(H.errors) do
                if i <= 3 then out("        ! error in " .. e.context .. ": " .. (e.err:match("^[^\n]*") or e.err) .. "\n") end
            end
            out("        last log lines:\n")
            H.dump_log(#H.log - 11, #H.log)
        end
        for _, w in ipairs(H.warnings) do out("        warn: " .. w.msg .. (w.count > 1 and (" (x" .. w.count .. ")") or "") .. "\n") end
        for _, r in ipairs(H.results) do
            if os.getenv("HARNESS_VERBOSE") then out("        " .. (r.ok and "ok " or "NO ") .. r.msg .. "\n") end
        end
    end
end

out(string.format("RESULT: %s  (%d passed, %d failed)\n", failed == 0 and "PASS" or "FAIL", passed, failed))
os.exit(failed == 0 and 0 or 1)
