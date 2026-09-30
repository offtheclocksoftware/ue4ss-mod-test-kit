--[[
  otc_selfcheck.lua  -  in-game self-checks for UE4SS Lua mods (Off the Clock) v1.0
  SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
  Each mod ships its own copy in <Mod>/Scripts/ (like otc_safe.lua).

  What it is for
    A test session should end with PASS/FAIL per mod without the tester having to describe what
    they saw. A mod registers a few checks ("effect X is active: read back value Y") and reports what
    it READ BACK from the game. This file only formats and de-duplicates the result lines in UE4SS.log:

      [SELFCHECK] <Mod> <check> PASS|FAIL|WAITING <detail>

    After a test session, search UE4SS.log for "[SELFCHECK]" (e.g. `Select-String UE4SS.log -Pattern SELFCHECK`
    or `grep SELFCHECK UE4SS.log`): the last line per check is its result, and the WAITING "how:" hints
    are the steps still to do in game.

  Rules (by design)
    * Pure Lua: this file never touches a UObject, never calls the game, never writes game state.
      The mod does the reading (inside its existing game-thread hook callbacks) and passes values in.
    * No timers, no LoopAsync, no ExecuteInGameThread, no key binds, no hooks of its own.
    * Zero cost when idle: gate any extra read-back with `if SC:want(id) then ... end`; want() is one
      table lookup and returns false once the check has a result.
    * Few lines: each check logs only when its state changes (max 5 lines per check), so a check
      called every frame still writes 2 lines per session.

  Usage in main.lua (the loader falls back to a silent stub if this file is missing):

      local SC = load_selfcheck("MyMod")   -- loader: see examples/FasterSprint/Scripts/main.lua
      SC:expect("boost_held", "load a save and hold a gun for 2 s")            -- WAITING line with the hint
      SC:expect("toggle_off", "press Num 4 once", { optional = true })
      ...
      if SC:want("boost_held") then SC:check("boost_held", value == wanted, "JumpZVelocity %.1f", value) end
      SC:pass(id, fmt, ...)      -- the read-back proved the effect
      SC:fail(id, fmt, ...)      -- the read-back proved the effect is NOT there (also after an earlier PASS)
      SC:check(id, ok, fmt, ...) -- ok -> PASS; not ok counts a miss, FAIL after `grace` misses (default 1)
      SC:wait(id, fmt, ...)      -- still waiting, with a reason (e.g. "you are not in a guild")
      SC:fail_open(fmt, ...)     -- every check without a result -> FAIL (e.g. the whole feature was disabled)

  Hint wording: short imperative steps a tester can do in game ("press Num 4, then jump"). Reuse the
  same words for the same action so a test checklist built from the hints stays short.
  Works with UE4SS 3.x Lua 5.4. No `...` inside non-vararg closures.
]]

local M = {}
M.__index = M
M.VERSION = "1.0"

local MAX_LINES_PER_CHECK = 5
local MAX_WAIT_REASONS = 3

local function fmt(f, ...)
    if f == nil then return "" end
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, tostring(f), ...)
    if ok then return s end
    return tostring(f) .. " [format error]"
end

-- One line per call; newlines inside a detail would break the report parser.
local function clean(s)
    s = tostring(s or "")
    s = s:gsub("[\r\n]+", " ")
    if #s > 300 then s = s:sub(1, 297) .. "..." end
    return s
end

local function safe_id(id)
    local s = tostring(id or "?"):gsub("%s+", "_")
    return s
end

function M.new(mod, opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.mod = safe_id(mod or "Mod")
    self.checks = {}   -- id -> { state = "WAITING"/"PASS"/"FAIL", misses, grace, lines, reasons, optional }
    self.order = {}
    self.quiet = opts.quiet == true   -- harness/unit tests only
    return self
end

function M:_emit(id, state, detail)
    local c = self.checks[id]
    if c then
        if c.lines >= MAX_LINES_PER_CHECK then return end
        c.lines = c.lines + 1
    end
    if self.quiet then return end
    local line = string.format("[SELFCHECK] %s %s %s", self.mod, id, state)
    if detail ~= nil and detail ~= "" then line = line .. " " .. clean(detail) end
    print(line .. "\n")
end

-- Register a check. `how` = what the tester does in game to reach it (logged with the WAITING line).
-- opts.optional = true: not reaching it doesn't make the session INCOMPLETE. opts.grace = misses before FAIL.
function M:expect(id, how, opts)
    id = safe_id(id)
    opts = opts or {}
    if self.checks[id] then return self end
    self.checks[id] = { state = "WAITING", misses = 0, grace = math.max(1, tonumber(opts.grace) or 1),
                        lines = 0, reasons = {}, nreasons = 0, optional = opts.optional == true }
    self.order[#self.order + 1] = id
    self:_emit(id, "WAITING", (opts.optional and "(optional) " or "") .. "how: " .. tostring(how or "?"))
    return self
end

-- True while the check is registered and has no result yet. The cheap gate for extra read-backs.
function M:want(id)
    local c = self.checks[id]
    return c ~= nil and c.state == "WAITING"
end

function M:state(id)
    local c = self.checks[id]
    return c and c.state or nil
end

function M:pass(id, f, ...)
    local c = self.checks[id]
    if not c or c.state == "PASS" then return false end
    local was = c.state
    c.state = "PASS"
    self:_emit(id, "PASS", fmt(f, ...) .. (was == "FAIL" and " (after an earlier FAIL)" or ""))
    return true
end

function M:fail(id, f, ...)
    local c = self.checks[id]
    if not c or c.state == "FAIL" then return false end
    local was = c.state
    c.state = "FAIL"
    self:_emit(id, "FAIL", fmt(f, ...) .. (was == "PASS" and " (after an earlier PASS)" or ""))
    return true
end

-- ok -> PASS. Not ok -> a miss; FAIL once `grace` misses were counted. No-op once the check has a result.
function M:check(id, ok, f, ...)
    local c = self.checks[id]
    if not c or c.state ~= "WAITING" then return false end
    if ok then return self:pass(id, f, ...) end
    c.misses = c.misses + 1
    if c.misses >= c.grace then
        return self:fail(id, "%s (%d time%s)", fmt(f, ...), c.misses, c.misses == 1 and "" or "s")
    end
    return false
end

-- Still waiting, with a reason. Each distinct reason is logged once (max 3 per check).
function M:wait(id, f, ...)
    local c = self.checks[id]
    if not c or c.state ~= "WAITING" then return false end
    local r = clean(fmt(f, ...))
    if c.reasons[r] or c.nreasons >= MAX_WAIT_REASONS then return false end
    c.reasons[r] = true
    c.nreasons = c.nreasons + 1
    self:_emit(id, "WAITING", r)
    return true
end

-- Every check without a result -> FAIL with this reason (the mod gave up / a feature was disabled).
function M:fail_open(f, ...)
    local why = fmt(f, ...)
    local n = 0
    for _, id in ipairs(self.order) do
        if self.checks[id].state == "WAITING" then
            self:fail(id, "%s", why)
            n = n + 1
        end
    end
    return n
end

return M
