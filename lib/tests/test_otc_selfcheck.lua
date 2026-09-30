-- Unit test for otc_selfcheck.lua (pure Lua, no game):  lua lib/tests/test_otc_selfcheck.lua
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local SCmod = dofile(here .. "/../otc_selfcheck.lua")

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = (tostring(s):gsub("\n$", "")) end

local fails = 0
local function eq(a, b, msg)
    if a ~= b then fails = fails + 1; real_print(string.format("FAIL %s (expected %s, got %s)", msg, tostring(b), tostring(a))) end
end
local function count(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

local sc = SCmod.new("Demo Mod")
sc:expect("a", "jump once")
sc:expect("b", "press Num 4, then jump", { optional = true })
sc:expect("c", "fire for 3 s", { grace = 3 })
sc:expect("a", "duplicate is ignored")
eq(lines[1], "[SELFCHECK] Demo_Mod a WAITING how: jump once", "WAITING line format")
eq(lines[2], "[SELFCHECK] Demo_Mod b WAITING (optional) how: press Num 4, then jump", "optional marker")
eq(#lines, 3, "duplicate expect ignored")

eq(sc:want("a"), true, "want while waiting")
for _ = 1, 100 do sc:check("a", true, "value %d", 7) end
eq(count("Demo_Mod a PASS value 7"), 1, "PASS logged once for 100 calls")
eq(sc:want("a"), false, "want false after PASS")

sc:check("c", false, "bloom"); sc:check("c", false, "bloom")
eq(count("Demo_Mod c FAIL"), 0, "grace: 2 misses are not a FAIL yet")
sc:check("c", false, "bloom")
eq(count("Demo_Mod c FAIL bloom (3 times)"), 1, "FAIL after 3 misses")
sc:check("c", true, "late")
eq(count("Demo_Mod c PASS"), 0, "check() is a no-op once FAIL")
sc:pass("c", "explicit")
eq(count("Demo_Mod c PASS explicit (after an earlier FAIL)"), 1, "explicit pass after FAIL is noted")

sc:fail("a", "went away")
eq(count("Demo_Mod a FAIL went away (after an earlier PASS)"), 1, "fail after PASS is noted")

sc:wait("b", "not in a guild"); sc:wait("b", "not in a guild"); sc:wait("b", "r2"); sc:wait("b", "r3"); sc:wait("b", "r4")
eq(count("Demo_Mod b WAITING not in a guild"), 1, "same reason once")
eq(count("Demo_Mod b WAITING r4"), 0, "max 3 reasons")

local sc2 = SCmod.new("X")
sc2:expect("p", "a"); sc2:expect("q", "b"); sc2:pass("p", "ok")
eq(sc2:fail_open("feature disabled: %s", "hook missing"), 1, "fail_open counts open checks")
eq(count("X q FAIL feature disabled: hook missing"), 1, "fail_open line")

local sc3 = SCmod.new("Y")
sc3:expect("z", "x")
for i = 1, 20 do if i % 2 == 0 then sc3:pass("z", "p") else sc3:fail("z", "f") end end
eq(count("Y z "), 5, "max 5 lines per check even when flapping")

sc3:pass("unknown", "x"); sc3:check("unknown", true); sc3:wait("unknown", "x")
eq(sc3:want("unknown"), false, "unknown ids are ignored")
eq(count("unknown"), 0, "nothing logged for unknown ids")

local sc4 = SCmod.new("N")
sc4:expect("n", "x"); sc4:fail("n", "multi\nline")
eq(count("N n FAIL multi line"), 1, "newlines flattened")

print = real_print
if fails == 0 then print("RESULT: PASS (otc_selfcheck " .. SCmod.VERSION .. ")") os.exit(0) end
print("RESULT: FAIL (" .. fails .. ")")
os.exit(1)
