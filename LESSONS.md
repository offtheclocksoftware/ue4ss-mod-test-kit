# UE4SS Lua modding: lessons learned the hard way

Rules from shipping UE4SS Lua mods for several Unreal Engine games, each with the reason behind it. "Seen" notes are real cases, kept short. Most of them were observed on UE4SS v3.0.1 Beta (git `f08dfdf`); newer builds may behave better, but every rule here is also simply a safer way to write a mod.

The offline harness (`harness/`) checks several of these automatically; the lint (`lint/`) checks a few more. The rest you check by hand. For a one-page checklist with sources (and the places where public advice disagrees with these rules), see [`docs/ENGINE-BEST-PRACTICES-UE4SS.md`](docs/ENGINE-BEST-PRACTICES-UE4SS.md).

## 1. Threading and hooks

- **Do the work inside a game-thread hook callback.** A post-hook on an event the game already fires at the right moment (for example `PlayerController:ClientRestart`, which fires on load, respawn and possession changes) leaves no timer, no queue and nothing running at quit. Rebuilding mods this way fixed a reproducible crash on quit.
- **For recurring work, hook a UFunction the game calls every frame on its game thread** (a Blueprint character's `ReceiveTick`, or a component `Tick` that the reflection dump lists as a UFunction). Keep the hook cheap: check the time first and do the real work a few times a second.
- **Don't use `RegisterKeyBind`, `RegisterKeyBindAsync`, `LoopAsync`, `ExecuteAsync`, `ExecuteWithDelay` or `ExecuteInGameThread` at all, not even for a callback that only flips a flag.** A mod has one Lua state, and any Lua that runs on a UE4SS thread races the same mod's game-thread hook callbacks, which take no lock. Seen in our own testing: a Palworld crash inside `luaL_ref` after about 1.5 hours idle, once a mod hooked a per-frame function while another callback ran on a UE4SS thread. On the ProcessEvent method, `ExecuteInGameThread` is drained from UE4SS's ProcessEvent hook on *any* thread that fires it, including animation worker threads (seen in our own High on Life development builds: 19 crash files in two days of testing, none after they were rebuilt hook-driven). The first `ExecuteInGameThread` call also installs that ProcessEvent hook on demand, which exposed another UE4SS hook bug (a mis-resolved `InitGameState` hook) and crashed a game on quit. UE4SS's own tracker has related reports (issues #168, #1180, #1345 and #1445), and a maintainer calls the async functions inherently unsafe (#1345). The harness (`forbid_off_thread`) and the lint fail on all of them. Note that the official guide's examples still use `RegisterKeyBind` with `ExecuteInGameThread`; we don't follow them.
- **The `*InGameThread*` delayed family (`ExecuteInGameThreadWithDelay`, `LoopInGameThreadWithDelay`, `...AfterFrames`) is banned too.** Newer UE4SS builds have it and upstream recommends it over the async functions, and with the EngineTick method it does run on the real game thread. It is still a queue that must be cancelled on quit and world change, it has a crash history (#1180), queueing into it from off-thread code races the hooks (#1445), and older builds don't have it. A per-frame game-thread hook with a time check does the same job with none of that.
- **Read hotkeys on the game thread.** `pc:IsInputKeyDown({ KeyName = FName("F5") })` from a per-frame game-thread hook, with edge detection (one press = one action; a key already held at startup does not fire). `lib/otc_keys.lua` does exactly that and `harness/examples/keybind_money` shows the bare pattern. Key names are Unreal FKey names (`NumPadFour`), not UE4SS names (`Key.NUM_FOUR`).
- **Keep `main.lua` top level to registration.** It runs on UE4SS's own thread at startup (and at every mod restart), not the game thread: register hooks and read config there, and do no UObject work and no `Find*`.
- **For recurring engine-side work, consider an engine timer instead of a Lua loop.** `KismetSystemLibrary.K2_SetTimer`, set from a hook, can call a verified, parameterless game function. It runs on the game thread, dies with its object and can't double up.
- **Hook `QuitGame` and stop everything on quit.** Also watch for the `quit`/`exit` console commands.
- **Don't keep UObject references between calls.** Store an address or a name and look the object up again each time; cached pointers dangle after a world change or respawn.
- **Act only when the local controller is driving the player's own character.** Possession changes (vehicles, mounts, ziplines, spectator or selector pawns) fire the same hooks with a temporary pawn. Seen: a crash 2-3 s after using a zipline.
- **Find functions return an invalid wrapper, not `nil`.** `FindFirstOf`, `StaticFindObject` and null object properties return an object whose `IsValid()` is false, so `if obj then` passes on "not found". Always write `obj and obj:IsValid()`.
- **Wrap `RegisterHook`, `FindFirstOf` and `StaticFindObject` in `pcall`.** On failure, log one "feature disabled due to game update" line and go idle instead of crashing or spamming.
- **Hooks only see calls that go through ProcessEvent.** Natively called functions, and inherited UFunctions hooked on a child-class path, never fire. Confirm a hook fires (with a one-time log line) before relying on it. Seen: hooks on HUD widget Blueprint functions registered fine but never fired; don't use widget functions as a timing signal.
- **Don't read hook parameters on functions that Blueprints call directly.** A native UFunction can be called both through ProcessEvent (parameters fine) and straight from Blueprint script, where some builds read the parameters from the wrong place. Seen: `param:get()` on an object parameter of an interface function crashed inside `UObjectBase::IsA`. Prefer changing the data the native code reads (for example a settings default object) over per-call hooks.
- **Check a UFunction's full reflected signature.** Missing arguments make the call throw ("expected 2 parameters, received 1"), and inside `pcall` that failure is silent. Seen: `SetMovementMode` needs both the mode and the custom-mode argument.
- **Don't test UFunctions with `type(obj.Fn) == "function"`.** UFunctions are userdata, so that check is always false and quietly sends the code down a fallback path.
- **Declare guard variables before any function that reads them.** A `local IsQuitting` declared after the function makes that function read an always-`nil` global. `luac -p -l main.lua` lists every global a script reads; the lint and the harness both flag it.
- **Log "applied" only after a verified success.** Console commands and cheats never fail loudly (unknown commands are silently ignored), and `pcall` swallows errors. Read the value back, or at least check the call's return value, before logging success.
- **Set engine state directly instead of relying on cheat commands.** Cheat commands can behave differently from what their names suggest (Fly/Ghost froze the character in one game). Use the proper setter (for example `SetActorEnableCollision`), because a raw property write before it can turn the setter into a no-op.
- **Check that an API exists in your UE4SS build.** For example the `*InGameThread*` delayed family, struct userdata and `ModRef.OnUnload` are missing from older builds such as `f08dfdf`. Name the exact build you tested on every page.
- **Register each hook once, at load, and never from inside a hook callback.** Every firing would add another registration. Don't return `true` from a `NotifyOnNewObject` callback and don't call `UnregisterHook` on builds affected by the shared-hook-thread bug (#1345): use a Lua "done" flag instead.
- **`FName("x")` adds the name when it doesn't exist.** A typo in a key or row name gives a valid-looking FName that never matches. To test whether a name exists, use `FName("x", EFindName.FNAME_Find)`.
- **For `/Game/...` (Blueprint) hook paths the callback is a post hook, and the function must already be loaded when you register.**

## 2. Game data (arrays, structs, inventories, saves)

- **TArrays are 1-based in UE4SS, so use one index style.** A fallback that "tries `arr[i+1]`, then `arr[i]`" hits a different element and silently overwrites a slot.
- **Reading entries of an array of structs can crash.** Seen: `array:ForEach` + `elem:get()` on a live object's array of structs crashed inside UE4SS's struct conversion as soon as the array had an entry. `GetArrayNum()` was safe. Read sizes, not entries, unless a test proves that array type is safe.
- **Struct arguments can't hold UObjects (on `f08dfdf`).** Passing a Lua table for a struct parameter with a UObject field (for example a data-table row handle) fails with `Value must be UObject or nil`, and passing a struct userdata is not implemented. Top-level object arguments work. Work around it with a function that takes a UObject, and read state from arrays or properties.
- **DataTables have their own Lua type** (`ForEachRow` / `FindRow`). Row objects handed to `ForEachRow` are only valid inside the callback.
- **Never put the same UObject into an array more than once.** Many slots pointing at one object duplicate items and crash when the game later consumes the stack.
- **Inventory arrays can be sparse or leave items out.** Walk slots with the game's own getter (a `GetItemInSlot`-style function) instead of trusting the raw `Items` array.
- **Don't write guessed fallback properties.** "If X is missing, write Y" can silently corrupt save data after a patch. Fail closed instead.
- **Don't replace a whole map or array from a hard-coded list.** A patch that adds a key gets wiped. Change only the entries the mod owns.
- **Pick containers and targets by identity, never "the first one".** A "first container" fallback edits the wrong container after a patch reorders them.
- **Don't touch the player or world during boot or save-load.** Wait until they're valid, and retry for a while before disabling a feature: data often fills in a few seconds after spawn.

## 3. Mod loader settings and quirks

- **In `mods.txt`, a comment on the same line as an entry makes UE4SS silently skip the mod.** Keep entries plain (`MyMod : 1`) and put comments on their own line.
- **Consider `HookInitGameState = 0`.** In some games UE4SS resolves "InitGameState" to the wrong function (seen: a spectate function), and its detour passes garbage, which crashed on quit. The only cost is that `RegisterInitGameState*` hooks stop working. The log line "Tried to hook InitGameState but function is unavailable" is harmless. Test it on your game before recommending it to players.
- **Be wary of other UE4SS "special" hooks on the same build.** `RegisterBeginPlay*` was suspected of the same mis-resolution. Prefer a normal `RegisterHook` on a verified UFunction path.
- **Prefer config over hooks when the engine exposes a setting.** A cvar or ini setting has fewer crash paths than runtime Lua, and it can't race the game.
- **Edit mod files and UE4SS ini settings only with the game closed, and back them up first.** Everything is read at launch; edits while the game runs create confusing half-states.
- **If a hotkey does nothing, read `UE4SS.log` before changing code.** Check that the mod loaded, that the key handling registered and whether the press was logged (and rule out Num Lock for numpad keys).
- **Use one loader per game.** If a game also has its own mod loader, pick one. One loader means one tested setup, one log and crashes you can attribute.

## 4. Respect the game's own rules

- **Go through the game's own action or ability path.** Seen: triggering a weapon's fire loop directly bypassed the game's restrictions (safe zones) and crashed with an access violation, especially from async threads; activating the game's own fire ability kept its rules in place. The same goes for cooldowns, costs and input-disabled states.
- **Never force an action the game blocks.** If the game says no, find out why before working around it.

## 5. Packaging

- **Put shared helper files inside the mod's own `Scripts` folder, and version-check them.** `main.lua` should refuse to run (with one log line) if the helper is older than it needs. Seen: a new `main.lua` installed next to an old helper copy.
- **Build zips with forward-slash paths and test the zip itself.** Extract it into a clean `ue4ss/Mods`: it should need no moving or renaming (`ModName/Scripts/main.lua`).
- **Re-verify PAK/IoStore asset overrides after every game patch.** A stale cooked asset is a classic crash on load.
- **One-shot mods** (unlocks, fixes) run once, leave a done marker, register nothing once done, and tell players to uninstall after use.
- **The header, README and mod page must describe what the code actually does**, and name the exact UE4SS build tested and any `UE4SS-settings.ini` lines the mod needs (with the reason for each).

## 6. Testing protocol

- **Run the offline harness before every release,** with `H.config.forbid_off_thread = true`, and keep the scenario file with the mod source. It catches background-thread UObject access, any off-thread Lua, declaration-order bugs, missing fail-closed paths and work that survives quitting.
- **Break the mod on purpose once** for each new scenario and confirm the scenario fails. A test that can't fail proves nothing.
- **Throttle logs and searches.** Log once, then back off (for example 1 s doubling to 10 s). Never log or search on every tick. Write one startup line and one line when the effect applies.
- **Test with only the mods under test enabled.**
- **End every test by quitting from the game's menu, then wait for the process to actually exit.** Unreal games often linger for up to a minute or more, and some crash during exit even with no mods. Crash files from force-closing through a launcher aren't real crashes.
- **Look everywhere crash evidence can land:** the game's `Saved/Crashes` and `Saved/Logs`, plus Windows Error Reporting (`%LOCALAPPDATA%\CrashDumps` and the Event Viewer Application log). Crashes during exit often leave no Unreal dump at all.
- **Get a baseline before blaming a mod.** Repeat the same steps with zero Lua mods, and ideally without UE4SS. A crash that also happens with no mods isn't the mod's fault.
- **Bisect when several mods are on.** Disable them one at a time (or half at a time) until the problem follows a single mod.
- **Test the transitions, not just the feature:** load, death or respawn, area travel, possession changes (vehicles, mounts, ziplines), return to the main menu, and quit.
- **Match the fix to the crash evidence.** The faulting module and stack (a UE4SS detour frame, an engine exit-time destructor, or the mod's own call) tell you whose bug it is. Don't ship a "fix" the dump doesn't support.
- **Let the mod grade itself.** `otc_selfcheck.lua` writes `[SELFCHECK] <Mod> <check> PASS/FAIL` lines from real read-backs, so a test session ends with a result instead of a guess.

## 7. Release checklist

- Harness passes, and the scenario file is kept with the source.
- Lint shows no ERROR (and ideally no WARN).
- `UE4SS.log` shows the mod's startup line and its applied line (and PASS self-checks, if used).
- Tested with only the shipped mods enabled, ended with a menu quit, process fully exited, no new crash file.
- The exact UE4SS build and any required `UE4SS-settings.ini` lines are written down in the README.
