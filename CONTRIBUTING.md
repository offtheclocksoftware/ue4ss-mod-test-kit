# Contributing

Thanks for helping make UE4SS modding a bit less crashy.

**Most useful:**
- **A UE4SS quirk or crash you hit**, with the UE4SS build, the game (or engine version), the smallest Lua that shows it, and what the log or crash dump said. Good ones become a harness option and a line in `LESSONS.md`.
- **A scenario the harness can't express yet.** Describe what the game does and what your mod expects.
- **Bug reports** for the harness, lint or helpers: the command you ran, the output, and your Lua version (`lua -v`).

**Pull requests:**
1. Keep it pure Lua 5.4 with no dependencies, and keep the style of the file you touch.
2. Add or update a test: a scenario in `harness/examples/`, a check in `lib/tests/`, or an expectation in `test_all.lua`. If you add a check that should catch a bug, show that it fails on a broken example (see the `old_*` and `bad_async` examples).
3. Run `lua test_all.lua` and make sure it prints `RESULT: PASS`.
4. No game files, no UE4SS source, no copyrighted game assets. Class and function names in scenarios are fine.
5. Examples and helpers follow the threading rule in the README: nothing runs off the game thread. If you think a case needs an exception, open an issue with the evidence (UE4SS build, the crash or the source line) before writing code.

By contributing you agree that your contribution is released under the MIT license of this project.

This is a spare-time project, so replies can take a few days. Everyone gets the same attention; there is no paid support.
