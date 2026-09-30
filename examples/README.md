# Examples

| Example | What it shows |
|---|---|
| [`FasterSprint/`](FasterSprint/README.md) | A complete small mod in the crash-safe pattern: one game-thread hook (`ClientRestart`), local-player check, fail-closed on game updates, verified writes, self-checks, and 8 harness scenarios. Start here. |
| [`../harness/examples/ammo_refill`](../harness/examples/ammo_refill/Scripts/main.lua) | A "keep doing X" mod: all work in a per-frame game-thread hook with a time check, working on the hook's own `self`. |
| [`../harness/examples/keybind_money`](../harness/examples/keybind_money/Scripts/main.lua) | A hotkey mod: `IsInputKeyDown` from a per-frame hook, edge detection, no `RegisterKeyBind`. |
| [`../harness/examples/old_queue_pattern`](../harness/examples/old_queue_pattern/Scripts/main.lua), [`old_keybind_pattern`](../harness/examples/old_keybind_pattern/Scripts/main.lua), [`bad_async`](../harness/examples/bad_async/Scripts/main.lua) | **What not to do**, kept so the harness and the lint have something to reject. `lua test_all.lua` checks that they are rejected. Never copy these. |

The target games in all examples are made up (stock Unreal class names, or `ExampleGame`). Take your real class, property and function names from your game's reflection dump.
