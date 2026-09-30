# UE4SS offline test harness

Runs a UE4SS Lua mod's real `Scripts/main.lua` against a fake UE4SS and a fake game, with no game running. It catches the mod bugs that cause most UE4SS Lua crashes before anyone plays the build.

**How to use it:** keep one scenario file per mod (for example `MyMod/tests/MyMod.scenarios.lua`, not inside the zip you give players) and run the harness before every release. Passing the harness doesn't replace testing in the game. It only means the build is worth testing there.

Read [`../LESSONS.md`](../LESSONS.md) too. The harness checks some of those lessons automatically. The rest you check by hand.

## Files

| File | What it is |
|---|---|
| `fake_ue4ss.lua` | Fake UE4SS API (hooks, keybinds, game-thread queue, background loops, Find*, UObjects, log capture) plus a simulated engine: frames, world change, quit/teardown. All of it lives in the global `H`. |
| `run.lua` | The runner. It loads the mod, runs each scenario, prints PASS/FAIL, and exits non-zero on any failure. |
| `run_lupa.py` | The same runner through Python + `lupa`, for when Lua isn't installed. |
| `examples/ammo_refill/` + `ammo_refill.scenarios.lua` | The **safe pattern** for a "keep doing X" mod: all work inside a hook on a per-frame game-thread UFunction, no threading API at all. 8 scenarios, run with `forbid_off_thread` on. |
| `examples/keybind_money/` + `keybind_money.scenarios.lua` | The **safe pattern** for a hotkey mod: the key is read with `IsInputKeyDown` from a per-frame game-thread hook, no `RegisterKeyBind`. 8 scenarios, run with `forbid_off_thread` on. |
| `examples/old_queue_pattern/`, `examples/old_keybind_pattern/` (+ scenarios) | **The banned pattern, kept on purpose** (`LoopAsync` + `ExecuteInGameThread`; `RegisterKeyBind` + `ExecuteInGameThread`). The harness must report FAIL on the `forbid_off_thread` scenario (exit code 1) and name the mod's `file:line`. Never copy these. |
| `examples/bad_async/` + `bad_async.scenarios.lua` | A **deliberately broken** mod (UObject access from `LoopAsync`, guard declared after use). The harness must report FAIL on it (exit code 1). |

## The safe pattern (the only one our examples teach)

Do not use `LoopAsync`, `ExecuteAsync`, `ExecuteWithDelay`, `ExecuteInGameThread`, the `*InGameThread*` delayed family or `RegisterKeyBind`, not even for a callback that only sets a flag: they run Lua on UE4SS threads (or drain a queue from whatever thread fires ProcessEvent), and a mod has one Lua state that its game-thread hooks use too. Instead:

1. Register **hooks** on UFunctions the game itself calls on its game thread (`RegisterHook`, at load, once). A per-frame one (a character's or HUD's tick/update function, taken from your reflection dump) is your clock: check `os.clock()` first and do the real work a few times a second.
2. Read **keys** in that hook: `pc:IsInputKeyDown({ KeyName = FName("NumPadOne") })` on the local player controller, with your own edge detection (see `examples/keybind_money`; a reusable version is `lib/otc_keys.lua`).
3. Work on the hook's own `self` where you can (no `FindFirstOf` per frame), `IsValid()`-check every object right before use, stop on the `QuitGame` hook, wait out world changes, and fail closed with one log line if a hook is missing after a game update.

Run every scenario with `H.config.forbid_off_thread = true` (both safe examples do): the harness then fails the run for any of the APIs above or any callback that runs off the game thread, and prints the offending `file:line`.

## Install (Windows, once)

Lua 5.4 from winget (package `DEVCOM.Lua`, Lua 5.4.6, which installs the `lua` and `luac` commands):

```powershell
winget install -e --id DEVCOM.Lua
# close and reopen PowerShell so PATH updates, then:
lua -v        # expect: Lua 5.4.x
```

**Fallback if winget or Lua won't install:** use Python with the `lupa` package. Its arguments and output are the same.

```powershell
python -m pip install --upgrade lupa
python harness/run_lupa.py <main.lua> <scenarios.lua>
```

## Run it (from the kit root; Windows, Linux and macOS)

Check the kit itself first (`lua test_all.lua` does all of this in one go), or one example at a time:

```
lua harness/run.lua harness/examples/ammo_refill/Scripts/main.lua harness/examples/ammo_refill.scenarios.lua
lua harness/run.lua harness/examples/keybind_money/Scripts/main.lua harness/examples/keybind_money.scenarios.lua
lua harness/run.lua harness/examples/bad_async/Scripts/main.lua harness/examples/bad_async.scenarios.lua                   # must FAIL
lua harness/run.lua harness/examples/old_queue_pattern/Scripts/main.lua harness/examples/old_queue_pattern.scenarios.lua   # must FAIL
lua harness/run.lua harness/examples/old_keybind_pattern/Scripts/main.lua harness/examples/old_keybind_pattern.scenarios.lua   # must FAIL
```

Then run it on your mod:

```
lua harness/run.lua path/to/MyMod/Scripts/main.lua path/to/MyMod/tests/MyMod.scenarios.lua
echo $?    # 0 = all passed, 1 = something failed   (PowerShell: $LASTEXITCODE)
```

You can pass several scenario files. Set the environment variable `HARNESS_VERBOSE=1` to print every individual check.

Also list every global your script reads. A name that should be a local (such as a quit flag) means a declaration-order bug:

```
luac -p -l path/to/MyMod/Scripts/main.lua | grep 'GETTABUP.*_ENV'      # PowerShell: ... | Select-String 'GETTABUP.*_ENV'
```

(`lint/lint.lua` in this kit does this check for you.)

## What it catches

Checked automatically in every scenario (any failure = FAIL):
- **UObject access from the background thread.** Any read, write, method call, `FindFirstOf`, `FindAllOf`, `StaticFindObject` or `StaticConstructObject` from inside `LoopAsync`, `ExecuteWithDelay`, `ExecuteAsync` or `RegisterKeyBindAsync` is reported with the mod's `file:line`. This is the classic UE4SS crash cause.
- **UObject access after world teardown.** After a menu quit, objects become invalid. Anything that still touches them is flagged.
- **Uncaught Lua errors in mod callbacks.** Hooks, loops, keybinds and game-thread work are all covered. This includes touching a destroyed object without an `IsValid()` check.
- **Compile errors** in `main.lua` or any `.lua` next to it.

Reported as warnings (read them, and fix them unless you have a reason not to):
- **Reads of globals that were never set.** This is the "guard variable declared after the function that reads it" bug: the function silently reads `nil`, so the guard never fires. The warning also shows up for intentional feature checks such as `if LoopInGameThreadWithDelay then`.
- **UObject access from the key-input thread** (plain `RegisterKeyBind`). Set `H.config.strict_input_thread = true` to make it a failure. Some UE4SS builds run keybind callbacks off the game thread.
- **UObject access during mod load**, if you set `H.config.warn_load_access = true`.

Failures when **`H.config.forbid_off_thread = true`** (set it in `setup`, or run with the environment variable `HARNESS_FORBID_OFF_THREAD=1`; we recommend it for every UE4SS mod):
- **Any off-game-thread API registered:** `RegisterKeyBind`, `RegisterKeyBindAsync`, `LoopAsync`, `ExecuteAsync`, `ExecuteWithDelay`, `ExecuteInGameThread`, and the InGameThread delayed family `ExecuteInGameThreadWithDelay`, `LoopInGameThreadWithDelay`, `RetriggerableExecuteInGameThreadWithDelay`, `ExecuteInGameThreadAfterFrames`, `LoopInGameThreadAfterFrames` (reported with the mod's `file:line`; under this flag the fake defines the whole family so a mod's `if LoopInGameThreadWithDelay then` check cannot hide a call). The `otc_safe` wrappers `S:after` / `S:loop` / `S:safe_key` are covered because they call these APIs when the mod sets `allow_game_thread_queue = true`; the report points at the mod's own call line.
- **Any callback that runs on the "async" or "input" thread**, even one that touches no UObject. On UE4SS 2281fa31 those threads run the mod's Lua state while its game-thread hooks run it too (no shared lock), which corrupted the Lua registry and crashed Palworld after 1.5 h idle. Read hotkeys on the game thread instead: `pc:IsInputKeyDown({ KeyName = FName("NumPadFour") })` from a per-frame hook, with your own edge detection.

Things your scenarios check (the examples show how): quitting in the middle of an action, world change, missing objects failing closed, a renamed hook function, log/search throttling, cheap per-frame hooks (real work a few times a second), hotkey edge detection (hold = one action, a key held at startup does not fire), and nothing registered or run off the game thread.

## What it can't catch

- **Real engine behavior.** The fake game is only as accurate as your scenario, and it can't tell you whether a UFunction really exists, what its real parameters are, or whether the game calls it through ProcessEvent (a hook only sees calls that go through ProcessEvent). Reading the game's reflection dump and testing in game are still required.
- **UE4SS settings (`UE4SS-settings.ini`).** For example, `HookInitGameState` can mis-hook in some games, and with `HookUObjectProcessEvent = 0` `ExecuteInGameThread` callbacks may never run in some builds (one more reason our mods don't use it). The harness can't read your ini or know your UE4SS build.
- **Native crashes, timing races, memory corruption, and TArray/struct layout mistakes.** Writing to the wrong array index or struct offset won't show up.
- **Save data effects, multiplayer and replication, and other mods loaded at the same time.**
- **Which UE4SS API exists in your build.** By default the fake leaves out `LoopInGameThreadWithDelay` and `ExecuteInGameThreadWithDelay`, because some older builds don't have them. If your pinned build does, set `H.config.has_loop_in_game_thread = true` in the scenario's `setup`.

## Write a scenario for a new mod

1. Copy `examples/ammo_refill.scenarios.lua` (or `keybind_money.scenarios.lua` for a hotkey mod) next to your mod source as `tests/<ModName>.scenarios.lua`.
2. In `setup`, build only the fake objects your mod touches, using the same class names, property names and function names the mod uses (take them from the game's reflection dump, not from guesses).
3. Write one scenario per behavior. At minimum:
   - **normal play**: the feature works, the "applied" log line appears, and there's no background-thread access
   - **quit mid-action**: `H.quit("menu")` while work is queued, then `H.quit_report()` shows nothing alive and nothing touched after teardown
   - **world change**: `H.change_world(builder)`. Old objects die, and the mod recovers on the new world.
   - **missing object / renamed property**: the mod fails closed, logs one "feature disabled due to game update" line, and backs off
   - **log throttling**: a long run logs a handful of lines, not one per tick
   - **renamed hook**: `H.missing_hooks[path] = true` makes `RegisterHook` throw as after a game update; the mod logs one line and idles
   - hotkey mods: **press, hold (one action), key held at startup (no action), press after quit**
4. Run it and fix the mod until it passes. Then break the mod on purpose once (for example, move one call into the `LoopAsync`) and confirm the scenario fails.

Skeleton:

```lua
local W
local TICK = "/Script/MyGame.MyCharacter:TickSomething"   -- a per-frame UFunction from your reflection dump
return {
  setup = function(H)
    H.config.forbid_off_thread = true              -- no threading API, no off-thread callbacks (set it again after any H.reset())
    local comp = H.obj("MyComponent_1", { Value = 10, MaxValue = 10 })
    W = H.player_world({ pawn_fields = { GetMyComponent = function() return comp end } })
    W.comp = comp
    H.every_frame_hook(TICK, function() return W and W.pawn end)   -- the game ticks the character on the game thread
  end,
  scenarios = {
    { name = "normal play", run = function(H)
        H.run(3)                                   -- 3 simulated seconds
        H.poke(W.comp, "Value", 1); H.run(0.2)     -- the game changes something
        H.eq(H.peek(W.comp, "Value"), 10, "restored")
        H.check(H.log_count("[MyMod] applied") >= 1, "applied line logged")
    end },
    { name = "quit mid-action", run = function(H)
        H.run(3); H.quit("menu")
        local r = H.quit_report(1.0)
        H.eq(#r.alive, 0, "no loops or timers left running")
    end },
  },
}
```

### `H` reference (the parts you'll use)

| Call | What it does |
|---|---|
| `H.obj(name, fields, opts)` | Fake UObject. Methods in `fields` are called as `obj:Method()`. `opts.strict = true` makes unknown members raise errors (useful for simulating a renamed property). `opts.class`, `opts.path` (for `StaticFindObject`), `opts.persistent` (survives world change), `opts.find = false`. |
| `H.class(name, parent, path)` | Fake UClass. `FindFirstOf`/`FindAllOf` match objects by class name, including parent classes. |
| `H.player_world(opts)` | World + game mode + player controller + pawn (`opts.pawn_fields`, `opts.pc_fields`, `opts.gm_fields`). |
| `H.array(list)` | TArray-like wrapper (1-based, `#`, `GetArrayNum`, `ForEach`). |
| `H.param(v)` | Hook-parameter wrapper (`:get()` / `:set()`). |
| `H.run(seconds)` / `H.tick(n)` | Advance time. Each 25 ms frame runs the background loops, then `H.on_frame` functions, then the `ExecuteInGameThread` queue. |
| `H.on_frame(fn)` | Your fake game logic, run every frame on the game thread. |
| `H.every_frame_hook(path, self_obj_or_fn, ...)` | The game calls a UFunction every frame on the game thread (the mod's clock). `self_obj_or_fn` is the object, or a function returning the current one (`nil` = nothing ticks, e.g. main menu). Stops after quit teardown. |
| `H.fire_hook(path, self, ...)` | The game calls a hooked UFunction. Pre/post callbacks run on the game thread. `H.hook_impl[path]` can hold the native body. |
| `H.press(Key.X, {ModifierKey.CONTROL})` | Press a key bound with `RegisterKeyBind` (only for testing banned legacy mods; use `H.key_down` for the safe pattern). |
| `H.key_down("NumPadFour", true/false)` | Hold/release a key for the fake `PlayerController:IsInputKeyDown` / `WasInputKeyJustPressed` (available on every fake object whose class chain contains `PlayerController`). `H.calls.IsInputKeyDown` counts reads; `H.key_reads[thread]` shows which thread read. |
| `H.spawn(obj)` | Fire `NotifyOnNewObject` callbacks for this object's class. |
| `H.console("cmd")` | Console command (fires `ExecuteConsoleCommand` hooks and handlers). |
| `H.change_world(builder)` | Level change. Every non-persistent object is invalidated, then `builder(H)` builds the new world. |
| `H.quit("menu" / "console" / "kill")` + `H.quit_report(sec)` | Quit. After `H.config.teardown_ticks` frames, all objects become invalid. The report lists loops or timers still alive, work scheduled after quit, and accesses after teardown. |
| `H.destroy(obj)`, `H.is_alive(obj)` | Destroy an object (`IsValid()` returns false, and any other access raises an error). |
| `H.peek(obj, k)`, `H.poke(obj, k, v)` | Read or write an object from the scenario without counting as mod access. |
| `H.missing_hooks[path] = true` | `RegisterHook` on that path throws, as it does when a game update renames the function. |
| `H.config.executor_alive = false` | The `ExecuteInGameThread` queue never runs (simulates `HookUObjectProcessEvent = 0` on builds that need it). |
| `H.config.keybind_thread` | `"input"` (default), `"game"` or `"async"`. |
| `H.config.forbid_off_thread = true` | Fail on any off-game-thread API or callback (rule for every UE4SS game; also `HARNESS_FORBID_OFF_THREAD=1`). |
| `H.check(cond, msg)`, `H.eq(a, b, msg)` | Assertions. |
| `H.log_count(text)`, `H.mark()`, `H.log_count_since(mark, text)`, `H.dump_log()` | Inspect the mod's `print` output. |
| `H.calls.FindAllOf`, `H.accesses["Obj.Prop"]`, `H.max_queue`, `H.async_violations()` | Counters for throttling and back-off checks (`H.max_queue` only matters for legacy queue code). |
| `package.loaded["UEHelpers"] = {...}` | Replace the default fake UEHelpers in `setup` if the mod needs other helpers. |
