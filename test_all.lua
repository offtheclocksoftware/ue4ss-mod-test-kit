--[[
test_all.lua - runs the kit's own checks. From the kit root:  lua test_all.lua   (add -v for full output)
  * unit tests for lib/otc_safe.lua, lib/otc_selfcheck.lua and lib/otc_keys.lua
  * the harness on every example (ammo_refill, keybind_money, FasterSprint must PASS;
    bad_async, old_queue_pattern and old_keybind_pattern must FAIL, which proves the checks can fail)
  * the lint: the safe examples pass --strict (no warnings either); the banned-pattern examples must fail it
  * the example mod's copies of otc_safe.lua / otc_selfcheck.lua match lib/
Exit code 0 only if every expectation holds.
SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
]]
local sep = package.config:sub(1, 1)
local WIN = sep == "\\"
local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local LUA = arg[-1] or "lua"
local verbose = arg[1] == "-v"

local function p(rel) return here .. "/" .. rel end
local function q(s) return '"' .. s .. '"' end

local function run(args)
    local cmd = q(LUA)
    for _, a in ipairs(args) do cmd = cmd .. " " .. q(a) end
    cmd = cmd .. " 2>&1"
    if WIN then cmd = '"' .. cmd .. '"' end           -- cmd.exe strips one outer pair of quotes
    local h = io.popen(cmd)
    local out = h:read("a")
    local ok, _, code = h:close()
    return (ok and 0 or code or 1), out
end

local total, bad = 0, 0
local function expect(label, want_code, args)
    total = total + 1
    local code, out = run(args)
    local good = (want_code == 0 and code == 0) or (want_code ~= 0 and code ~= 0)
    local last = ""
    for line in out:gmatch("[^\r\n]+") do if line:find("RESULT") or line:find("^lint:") then last = line end end
    io.write(string.format("%s  %-58s %s\n", good and "ok  " or "BAD ", label, last))
    if verbose or not good then io.write(out) end
    if not good then bad = bad + 1 end
end

local function same_file(a, b)
    local fa, fb = io.open(a, "rb"), io.open(b, "rb")
    if not fa or not fb then return false end
    local sa, sb = fa:read("a"), fb:read("a")
    fa:close(); fb:close()
    return sa == sb
end

io.write("UE4SS crash-safe mod kit: self-test\n")
expect("unit test: otc_safe", 0, { p("lib/tests/test_otc_safe.lua") })
expect("unit test: otc_selfcheck", 0, { p("lib/tests/test_otc_selfcheck.lua") })
expect("unit test: otc_keys", 0, { p("lib/tests/test_otc_keys.lua") })
local function harness(name) return { p("harness/run.lua"), p("harness/examples/" .. name .. "/Scripts/main.lua"), p("harness/examples/" .. name .. ".scenarios.lua") } end
for _, e in ipairs({ "ammo_refill", "keybind_money" }) do
    expect("harness: " .. e .. " (must pass)", 0, harness(e))
end
for _, e in ipairs({ "bad_async", "old_queue_pattern", "old_keybind_pattern" }) do
    expect("harness: " .. e .. " (must FAIL)", 1, harness(e))
end
expect("harness: examples/FasterSprint (must pass)", 0, { p("harness/run.lua"), p("examples/FasterSprint/Scripts/main.lua"), p("examples/FasterSprint/tests/FasterSprint.scenarios.lua") })
expect("lint: safe examples --strict (no findings)", 0, { p("lint/lint.lua"), p("harness/examples/ammo_refill"), p("harness/examples/keybind_money"), p("examples"), "--strict" })
for _, e in ipairs({ "bad_async", "old_queue_pattern", "old_keybind_pattern" }) do
    expect("lint: " .. e .. " (must FAIL)", 1, { p("lint/lint.lua"), p("harness/examples/" .. e) })
end
expect("lint: --warn-threading downgrades to a warning", 0, { p("lint/lint.lua"), p("harness/examples/old_queue_pattern"), "--warn-threading" })

for _, f in ipairs({ "otc_safe.lua", "otc_selfcheck.lua" }) do
    total = total + 1
    local good = same_file(p("lib/" .. f), p("examples/FasterSprint/Scripts/" .. f))
    io.write(string.format("%s  %-58s\n", good and "ok  " or "BAD ", "examples/FasterSprint copy of " .. f .. " matches lib/"))
    if not good then bad = bad + 1 end
end

io.write(string.format("RESULT: %s  (%d of %d expectations met)\n", bad == 0 and "PASS" or "FAIL", total - bad, total))
os.exit(bad == 0 and 0 or 1)
