"""Fallback runner when no Lua 5.4 executable is installed: runs run.lua inside Python via lupa.

    py -m pip install lupa
    py run_lupa.py <Mod\\Scripts\\main.lua> <scenarios.lua> [...]

Same arguments, output and exit code as `lua run.lua ...`.

SPDX-License-Identifier: MIT - Copyright (c) 2026 Off the Clock Software
"""
import os
import sys

try:
    import lupa.lua54 as lupa_mod  # lupa >= 2.0 ships a Lua 5.4 runtime
except ImportError:
    sys.exit("lupa with Lua 5.4 is required: py -m pip install --upgrade lupa")

here = os.path.dirname(os.path.abspath(__file__))
run_lua = os.path.join(here, "run.lua").replace("\\", "/")
lua = lupa_mod.LuaRuntime(unpack_returned_tuples=True)
set_arg = lua.eval("function(t) arg = {} ; for k, v in pairs(t) do arg[k] = v end end")
set_arg(lua.table_from({0: run_lua, **{i + 1: a for i, a in enumerate(sys.argv[1:])}}))
sys.stdout.flush()
lua.globals().dofile(run_lua)  # run.lua ends with os.exit(code)
