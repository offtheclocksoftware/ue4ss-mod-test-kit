# UE4SS Lua best practices (Palworld, High on Life and a UE4 survival game)

Written 2026-09-29 (Off the Clock) from our own crash evidence plus the public sources listed at the end (all accessed 2026-09-29). Not official UE4SS documentation. Our builds: **High on Life and a UE4 survival game run UE4SS `f08dfdf` (2025-12-05)**, **Palworld runs the Okaetsu Palworld build of upstream `2281fa31` (2026-08-29)**. Both log as "v3.0.1 Beta"; there is no v4 release yet (the changelog's v4.0.0-rc1 section is still "TBD").

Tags: **[OURS]** = learned from our own crashes/tests. **[PUBLIC]** = found in docs, source, issues or community guides. **[BOTH]** = we found it and a public source confirms it.

Short answer: there is no single best-practices page for UE4SS. The official docs describe what each function does, not which thread it runs on or how it fails. The real knowledge sits in the GitHub issue tracker, the source code and Discord. Our crash analyses are ahead of the public docs on threading. The docs even show a pattern we've proven crashes (see "Contradictions").

---

## 1. One-page checklist

| # | Rule | Why | Source |
|---|---|---|---|
| 1 | **No Lua may run off the game thread. Don't use `RegisterKeyBind`, `RegisterKeyBindAsync`, `LoopAsync`, `ExecuteAsync` or `ExecuteWithDelay`, not even for a flag flip.** | A mod has one Lua state. Those callbacks run on UE4SS threads with no lock shared with hook callbacks, so they corrupt the state (Palworld crash in `luaL_ref` after 1.5 h idle). | [BOTH] our Palworld crash analysis; issues #168, #1345, #1445; maintainer: async functions are "inherently unsafe" (#1345, 2026-07-17) |
| 2 | **Don't use `ExecuteInGameThread` or the `*InGameThread*` delayed functions** (`ExecuteInGameThreadWithDelay`, `LoopInGameThreadWithDelay`, `Retriggerable...`, `...AfterFrames`). Drive everything from `RegisterHook` on UFunctions the game calls on its game thread. | With the ProcessEvent method, UE4SS drains the queue on **whatever thread calls ProcessEvent**, including animation workers (HoL: 19 crashes, then 0 after the rebuild). On `main`, `process_event_hook` still has no game-thread check. Queueing from off-thread code races `hook_lua` (#1445). | [OURS] High on Life crash analysis; [PUBLIC] LuaMod.cpp at `main`/`2281fa31`, #1180, #1445. Public docs recommend these; see Contradictions |
| 3 | Read hotkeys on the game thread: `pc:IsInputKeyDown({KeyName = FName("NumPadFour")})` from a per-frame game-thread hook, with our own edge detection (`lib/otc_keys.lua` in this kit). | Replaces `RegisterKeyBind` (rule 1). | [OURS] |
| 4 | Keep `main.lua` top-level code to **registration only** (RegisterHook, config read). Do no UObject work and no Find* at load. | `main.lua` runs on the UE4SS event-loop thread, not the game thread, at first start and at every restart (#1445). | [PUBLIC] #1445 (2026-09-28); harness has `warn_load_access` |
| 5 | Always write `obj and obj:IsValid()`, never `if obj then`. | `FindFirstOf`, `StaticFindObject`, null object properties and `FWeakObjectPtr:Get()` return an invalid wrapper, not `nil`. | [BOTH] our lesson; docs FindFirstOf / FWeakObjectPtr |
| 6 | Don't keep UObject references between callbacks. Look them up again each time, or cache a name and re-find. | Pointers dangle after a world change, respawn or GC. | [BOTH] our lesson; ue4ss-common README ("do not retain borrowed Unreal structs across callbacks") |
| 7 | A hook only sees calls that go through ProcessEvent/script. Confirm with a one-time log line that it fires. | Natively called functions, and inherited functions hooked on a child path, never fire. | [OURS] |
| 8 | **For `/Game/...` (Blueprint) paths, the RegisterHook callback is a POST hook, and the function must already be loaded when you register.** `/Script/...` paths: the 2nd arg is pre, the 3rd is post. | Registering a BP function before its class loads fails. A "pre" callback on a BP path actually runs after. | [PUBLIC] docs RegisterHook; changelog v3.0.0 ("for BP-only functions, both callbacks act as post callbacks") |
| 9 | Don't read hook params on functions that Blueprints call directly (interface functions). | On f08dfdf, `p:get()` on an object param crashed in `UObjectBase::IsA` (HoL God Mode). | [OURS] |
| 10 | **Don't return `true` from `NotifyOnNewObject` callbacks and don't call `UnregisterHook`** on our builds. Use a Lua "done" flag instead. | Unfixed UE4SS bug: the mod's shared hook thread is anchored by whichever callback registered first. Removing that callback lets Lua garbage-collect the hook thread while other hooks still use it (use-after-free). The fix PR #1346 was closed unmerged, and the code is unchanged in `2281fa31`. | [PUBLIC] #1345, #1346 (2026-07-17); source check 2026-09-29 |
| 11 | Register each `NotifyOnNewObject` / `RegisterHook` **once**, at load. Never register from inside a hook callback. | Every firing adds another registration, which piles up callbacks and costs performance. | [PUBLIC] docs NotifyOnNewObject "What NOT to do"; pwmodding.wiki UE4SS functions |
| 12 | Avoid the special hooks `RegisterInitGameState*`, `RegisterBeginPlay*`, `RegisterEndPlay*`, `RegisterLoadMap*`, `RegisterCustomEvent`. Prefer RegisterHook on a verified UFunction. | f08dfdf resolved InitGameState to the wrong function. Before PR #1170 (2026-01-26, **not in f08dfdf**), these special-hook callbacks ran on the registering Lua thread instead of the hook thread ("callbacks executed in the wrong thread"). | [BOTH] our lesson; changelog #1170 |
| 13 | Check a UFunction's full reflected signature before calling it. Missing args throw, and `pcall` swallows the throw. | `SetMovementMode` needs 2 args. | [OURS] |
| 14 | Log "applied" only after reading the effect back (see `lib/otc_selfcheck.lua`). | Cheats and console commands fail silently. | [OURS] |
| 15 | TArrays are 1-based. **Never index past `#arr`: a write out of range silently grows the array.** | Since v3.0.0 "TArrays are now resized when being indexed into if necessary". A stray `arr[n+1]` adds an element to game data. | [BOTH] our 1-based lesson; changelog v3.0.0 |
| 16 | On f08dfdf, read array sizes, not struct entries. Don't pass struct tables that contain UObjects. | Crashes / `push_objectproperty` errors. Struct-as-userdata only arrived in PR #1169 (in 2281fa31, **not** f08dfdf). | [BOTH] our lesson (a UE4 survival game); changelog #1169 |
| 17 | `FName("x")` **adds** the name when it doesn't exist. To test whether a name exists, use `FName("x", EFindName.FNAME_Find)` (or `FindFName` from UEHelpers). | A typo in a key or row name gives a valid-looking FName that never matches, so the key never fires and nothing errors. | [PUBLIC] docs FName; changelog (FNAME_Add default) |
| 18 | Wrap RegisterHook/Find* in `pcall`. On failure, log one "disabled (game update?)" line and go idle. | Fail closed after patches. | [OURS] |
| 19 | Guard variables are declared before the functions that read them. `luac -p -l` lists globals. | Otherwise the function reads an always-nil global. | [OURS] |
| 20 | Throttle logs and searches (log once, then back off). Never on every tick. | Log spam and hitches. | [OURS] |
| 21 | `mods.txt`: no inline comments. A folder with `enabled.txt` loads even when set to 0. | The mod is silently skipped / still runs "disabled". | [BOTH] ours; changelog v1.3.6 (enabled.txt) |
| 22 | Keep `HookUObjectProcessEvent = 0` where no mod needs it (HoL). `HookInitGameState = 0` except on Palworld (BPModLoaderMod needs it). | Fewer UE4SS detours means fewer crash paths. | [OURS] |
| 23 | Pin and name the exact UE4SS build on every page. Check that an API exists in that build before using it. | APIs differ a lot: `f08dfdf` lacks the delayed-action system, struct userdata and `ModRef.OnUnload` (PR #1394). | [BOTH] ours; changelog |
| 24 | Palworld: use the Okaetsu `experimental-palworld` build (upstream binaries + `MemberVariableLayout.ini`). Never add `UE4SS_Signatures`, and don't run anything older than 3.0.1. | The layout file prevents bad member offsets. Keep that file when updating UE4SS. | [PUBLIC] pwmodding.wiki troubleshooting; #1377 ("the fork only adds a MemberVariableLayout.ini") |
| 25 | Test protocol: baseline without mods and without UE4SS, bisect, test the transitions (load, death, travel, mounts, menu, quit), menu quit then wait for the process to exit, check every crash location, match the fix to the dump. | Exit crashes are sometimes vanilla (seen on a UE4 survival game). | [OURS] |

---

## 2. Details

### 2.1 The threading model, from the source (verified 2026-09-29)

What runs where on our two builds (from `UE4SS/src/Mod/LuaMod.cpp` at `f08dfdf`, `2281fa31` and `main`; `main` differs from `2281fa31` only in small fixes):

| API | Thread the Lua callback runs on | Lock vs the mod's hook callbacks | Our verdict |
|---|---|---|---|
| `RegisterHook` callbacks | Whatever thread runs that UFunction. For game-thread UFunctions that is the game thread. | none (none needed if everything else stays on the game thread) | **Use** |
| `NotifyOnNewObject` | The game thread directly. Constructions on loading threads are queued and drained from the ProcessEvent/EngineTick hook (on `2281fa31`/`main`). | none | Use, register once, never `return true` (rule 10) |
| `RegisterKeyBind` | UE4SS event-loop "UpdateThread" | takes `m_thread_actions_mutex`, which hook callbacks never take | **Banned** |
| `RegisterKeyBindAsync` | UpdateThread | none | **Banned** |
| `LoopAsync`, `ExecuteAsync`, `ExecuteWithDelay` | the per-mod async thread (`update_async`, every 5 ms) | none | **Banned** (upstream: deprecated/unsafe) |
| `ExecuteInGameThread` (ProcessEvent method) | whatever thread calls ProcessEvent next, **including animation workers** | queue move only | **Banned** (HoL crashes) |
| `ExecuteInGameThread` (EngineTick method) | the real game thread (`UEngine::Tick`) | queue move only | Banned for now (see 2.2) |
| `*InGameThreadWithDelay`, `*AfterFrames` | same as above, per method; they exist only on `2281fa31`+ (PR #1128, 2025-12-24) | queue move only | Banned for now (see 2.2) |
| `main.lua` top level | UE4SS event-loop thread (#1445) | none | Registration only |

Defaults: `DefaultExecuteInGameThreadMethod = EngineTick` in the shipped `main` settings and in our **Palworld** ini. f08dfdf (HoL and the survival game) only has the ProcessEvent path, which needs `HookUObjectProcessEvent = 1`.

### 2.2 Could we ever allow the game-thread delayed functions?

Upstream maintainers now say: use `ExecuteInGameThreadWithDelay`/`LoopInGameThreadWithDelay` instead of the async functions (#1345, #1377; docs LoopAsync/ExecuteAsync pages; upgrade guide). On `2281fa31`+ with the **EngineTick** method, those callbacks do run on the real game thread. The remaining risks:

- **Queueing from off-thread code races `hook_lua`**, e.g. from `main.lua` top level or a keybind (#1445, 2026-09-28, open). Our rules 1 and 4 already remove every off-thread caller.
- **Overlapping queued callbacks crashed in `process_simple_actions`** (#1180, fixed by PR #1201, merged 2026-06-07; in `2281fa31`, not in f08dfdf). Follow-up reports in that thread still crashed during level transitions with `ExecuteInGameThreadWithDelay`.
- **Callbacks outlive the world.** A timer has to be cancelled on quit and world change, or it touches dead objects.
- **On f08dfdf only the ProcessEvent path exists**, which drains on worker threads. So these stay banned on every f08dfdf game regardless.

Our position: keep the ban. If a Palworld feature truly needs a timer, the candidate exception is `LoopInGameThreadWithDelay(ms, fn, ...)` with an explicit `EGameThreadMethod.EngineTick`, created **only from inside a game-thread hook callback**, cancelled on quit/world change, plus a long idle test (3.5 h+). Until then, a per-frame game-thread hook with a time check does the same job.

### 2.3 Object validity and lifetime
- Invalid wrappers instead of nil (rule 5). `RemoteUnrealParam` (hook params) has no `IsValid`; call `:get()` and then check the object. [PUBLIC docs]
- `AActor:GetWorld()`/`GetLevel()` return an invalid UObject, not nil (PR #810). [PUBLIC]
- Row objects from `UDataTable:ForEachRow` are valid only inside the callback. [OURS] `ForEach` callbacks can return `true` to stop early (on 2281fa31+). [PUBLIC]
- Possession changes (mounts, vehicles, ziplines) fire the same hooks with a temporary pawn. Act only when the local controller drives the player's own character. [OURS]

### 2.4 Strings and names
- `FString`: plain Lua strings convert automatically when you set StrProperty/FString params. Call `:ToString()` to read. [PUBLIC docs FString]
- `FName`: `FName("x")` = FNAME_Add (rule 17). Key names for `IsInputKeyDown` must match UE's `EKeys` names exactly (`NumPadFour`, not `Numpad4`). [OURS + PUBLIC]
- The v4.0.0-rc1 changelog fixes "random crashes (use-after-free) caused by the string intern pool", mostly Lua GC'd strings from UObject member access (PR #1271, 2026-06-14; in 2281fa31, **not** in f08dfdf). Suspect this on f08dfdf crashes with string frames. [PUBLIC]

### 2.5 Loader, settings, packaging
- The `ue4ss\` subfolder layout is the new default (the proxy `dwmapi.dll` stays next to the exe). [PUBLIC changelog]
- A config file in `Scripts\config.lua`, returned as a table and loaded with `require`, is the Palworld community convention. [PUBLIC pwmodding.wiki config-files] Our mods already do this.
- Vortex: pwmodding.wiki says to avoid Vortex/CurseForge for Palworld UE4SS installs. Our zips still carry `enabled.txt` for Vortex, so keep the manual install steps on every page. [PUBLIC]
- Zips: forward slashes, `ModName/Scripts/main.lua`, extract the zip itself into a clean `Mods` folder and test that. [OURS]

---

## 3. Contradictions: public advice vs our rules

| Public advice | Where | Our evidence | What we do |
|---|---|---|---|
| `RegisterKeyBind(... function() ExecuteInGameThread(function() ReadPlayerLocation() end) end)` | Official guide "Creating a Lua mod" (`docs/guides/creating-a-lua-mod.md`, current `main`) and the bundled **BPModLoaderMod** (`RegisterKeyBind(Key.INS, ... ExecuteInGameThread(LoadMods ...))`) | HoL f08dfdf: `ExecuteInGameThread` callbacks ran on animation worker threads, which caused access violations, a corrupted queue (`Registry::get_function_ref` -> abort) and hook-param crashes. 19 crash files Sep 27-28, zero across 3 sessions after the rebuild. Palworld 2281fa31: keybind callbacks run on UpdateThread, racing the same mod's hooks (source + dump). #1445 confirms that keybind callbacks and `main.lua` run off the game thread and race `hook_lua`. | Keep the ban. On Palworld, BPModLoaderMod only runs that code when Insert is pressed. Don't press Insert while testing, and note it if a crash follows. |
| Keybind callback reading a flag set by hooks (`AnyWidgetsOpen` example) | docs `registerkeybind.md` "Advanced Example" | Same race: a keybind thread and hook callbacks share one Lua state with no common lock (Palworld review section 2) | Read keys in a hook instead (rule 3) |
| "Use `ExecuteInGameThread`, it runs on the game thread" | docs `executeingamethread.md` ("executes code on the game thread") | True only for the EngineTick method. The ProcessEvent method drains on any thread that calls ProcessEvent. `process_event_hook` has no `IsInGameThread` check even on `main` (2026-09-29). | Ban stays; see 2.2 |
| Use `ExecuteInGameThreadWithDelay`/`LoopInGameThreadWithDelay` instead of async | maintainers in #1345 (2026-07-17) and #1377 (2026-08-12); LoopAsync/ExecuteAsync doc pages; upgrade guide | Better than async, but still has open races (#1445), a crash history (#1180), and doesn't exist on f08dfdf | Not used; see 2.2 |
| `ExecuteWithDelay`/`LoopAsync` shown as normal tools | pwmodding.wiki "UE4SS Function Overview"; Teh's Palworld Lua tutorial gist (active 2026-07) | Our Palworld idle crash came from exactly this (a third-party mod's 10 s loop; one of our own earlier mods had the same pattern). Upstream calls them deprecated and unsafe. | Ban. |
| `UnregisterHook` inside the callback to hook "once" | docs `registerhook.md` example | #1345/#1346: removing the first-registered callback can free the shared hook thread (use-after-free). #1010 fixed a different UnregisterHook-in-callback crash. | Use a Lua `done` flag and leave the hook registered |

---

## 4. Where to look when stuck

| Source | URL | Good for |
|---|---|---|
| RE-UE4SS source (`UE4SS/src/Mod/LuaMod.cpp`) at our exact commit | https://github.com/UE4SS-RE/RE-UE4SS (use `/blob/f08dfdff.../` or `/blob/2281fa31.../`) | **The only reliable answer to "which thread, which lock"**. Always read it at the commit the log names. |
| UE4SS changelog | https://github.com/UE4SS-RE/RE-UE4SS/blob/main/assets/Changelog.md | What changed per PR; check whether a fix is in our build with `gh api repos/UE4SS-RE/RE-UE4SS/compare/<pr-merge-sha>...<our-sha> --jq .status` ("ahead" = included) |
| UE4SS issue tracker | https://github.com/UE4SS-RE/RE-UE4SS/issues | Crash reports with maintainer answers. Best recent ones: #1445 (off-thread races), #1345/#1346 (hook thread GC), #1180 (queue crash), #1377 (LoopAsync on Palworld), #1385 (UnregisterHook inside a callback), #168 (async design) |
| UE4SS docs (dev = `main`) | https://docs.ue4ss.com/dev/ (API: `/dev/lua-api/global-functions/...`) | Signatures, overloads, class methods, settings. **Not** thread safety. The non-`dev` docs are older. |
| UE4SS upgrade guide | https://github.com/UE4SS-RE/RE-UE4SS/blob/main/docs/upgrade-guide.md | Breaking changes 3.x -> 4.x (FName default, async deprecation) |
| Default settings ini | https://github.com/UE4SS-RE/RE-UE4SS/blob/main/assets/UE4SS-settings.ini | What each hook/setting does, and defaults to compare with your live ini |
| Unreal Engine Modding Discord | link from the UE-Modding-Tools databank | Maintainers answer here; "guides" forum channel. |
| UE-Modding-Tools databank | https://github.com/Buckminsterfullerene02/UE-Modding-Tools | Index of tools, guides and per-game Discords |
| Palworld Modding Docs | https://pwmodding.wiki/ (troubleshooting, Lua modding, Workshop/Thunderstore publishing) | Palworld-specific loader advice (experimental-palworld fork, MemberVariableLayout, Workshop). Threading advice there is outdated (uses LoopAsync). Palworld Modding Discord: https://discord.gg/qHTZNcvYsv |
| Okaetsu RE-UE4SS fork | https://github.com/Okaetsu/RE-UE4SS (branch `experimental-palworld`; its issues are disabled, so reports go upstream) | The build most Palworld players run |
| ue4ss-common | https://github.com/my-mods/ue4ss-common | Peer library whose rules match ours (game-thread only, no borrowed structs across callbacks) |

---

## 5. Keeping this checklist current

1. **Changelog diff:** `gh api repos/UE4SS-RE/RE-UE4SS/commits?since=<last-check-date> --jq '.[].commit.message' | head -100`. Read any entry touching `LuaMod.cpp`, "thread", "delayed", "hook", "crash".
2. **Issues:** `gh api -X GET search/issues -f q='repo:UE4SS-RE/RE-UE4SS is:issue created:>=<last-check> (thread OR crash OR Lua)'`. Read maintainer replies on anything touching the APIs you use. Follow #1445 and #1345 until they close.
3. **Is a fix in your build?** For each relevant merged PR, run the compare command (section 4) against the commit your game runs.
4. **Record** new pitfalls here with date, source and tag, and bump the date at the top. If a rule changes, change the kit's lint and harness in the same commit.

---

## 6. Which part of this kit enforces which rule

| Rule | Enforced by | Not checked yet |
|---|---|---|
| 1 off-thread APIs | lint ERROR; harness `forbid_off_thread` (registration and any callback run on a UE4SS thread) | none |
| 2 `ExecuteInGameThread` and the `*InGameThread*` family | lint ERROR for all of them (also inside `pcall(...)`); harness reports each call with the mod's `file:line`, and the `otc_safe` opt-in wrappers at the caller's line | none |
| 3 keys in hooks | `lib/otc_keys.lua`; harness `H.key_down` / `IsInputKeyDown` model | none |
| 4 `main.lua` registration only | harness `warn_load_access` (opt-in) | on by default; lint warning for `Find*` at file top level |
| 5 IsValid | lint WARN for `FindFirstOf` / `StaticFindObject` results | `FindAllOf` elements, `:get()` of object params |
| 6, 7, 9 lifetime, hook fires, hook params | scenarios you write (world change, quit, "hook fired" log line) | |
| 10 `NotifyOnNewObject` `return true` / `UnregisterHook` | none | lint warning |
| 11 register once | none | lint warning for `RegisterHook` / `NotifyOnNewObject` inside a function body |
| 12 special hooks | lint INFO | |
| 15, 16 TArray growth, struct entries | none | fake TArray: out-of-range write fails |
| 17 FName typos | none | lint: check `KeyName = FName("...")` against the `EKeys` list |
| 18, 20 fail closed, throttle | scenarios (see the harness examples) | |
| 19 globals | lint WARN and harness warning | none |

Contributions for the "not checked yet" column are welcome (see CONTRIBUTING.md).
