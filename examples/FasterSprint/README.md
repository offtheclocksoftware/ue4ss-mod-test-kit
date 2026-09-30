# Example mod: Faster Sprint

A complete small UE4SS Lua mod written the crash-safe way, with its offline test scenarios. The target is a made-up game, but it uses stock Unreal names (`Character.CharacterMovement`, `CharacterMovementComponent.MaxWalkSpeed`, `PlayerController:ClientRestart`), so the same idea works in many Unreal games once you've checked the names in your game's reflection dump.

**What it does:** your character walks and runs faster (x1.5 by default; `Scripts/config.lua`, range 1.0 to 3.0).

## Files

```
FasterSprint/
  Scripts/
    main.lua            the mod
    config.lua          player settings
    otc_safe.lua        crash-safe helpers (copy of lib/otc_safe.lua)
    otc_selfcheck.lua   self-check lines (copy of lib/otc_selfcheck.lua)
  tests/
    FasterSprint.scenarios.lua   offline harness scenarios (not shipped to players)
```

Players install the `FasterSprint` folder without `tests/` into `ue4ss/Mods/` and enable it in `mods.txt` (`FasterSprint : 1`, no comment on the same line).

## What to look at

- **One game-thread hook does everything.** `Safe:on_restart(...)` registers a post-hook on `PlayerController:ClientRestart`, which the game fires on load, respawn and possession changes. No `LoopAsync`, no `ExecuteInGameThread`, no timers, no keybinds.
- **Local player only.** It checks `IsLocalPlayerController()` before touching anything.
- **Fails closed.** If a game update removes `CharacterMovement`, renames `MaxWalkSpeed` or the hook, the mod logs one `feature disabled: ... game update changed ...` line and goes idle. No errors, no spam.
- **Never stacks.** It remembers the original speed per movement component (by address, not by keeping the object) so repeated restarts don't multiply again.
- **Verified writes.** `Safe:set_num` writes, reads back, and only then logs "applied".
- **Self-checks.** `UE4SS.log` gets `[SELFCHECK] FasterSprint speed_applied PASS ...` from the value actually read back.

## Test it

From the kit root:

```
lua harness/run.lua examples/FasterSprint/Scripts/main.lua examples/FasterSprint/tests/FasterSprint.scenarios.lua
lua lint/lint.lua examples --strict
```

The 8 scenarios cover: first load, repeated restarts (no stacking), world change, config clamping, a missing component, a renamed property, a renamed hook, and quitting.
