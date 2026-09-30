# BepInEx best practices (Subnautica = BepInEx 5 Mono; BALL x PIT, Vampire Survivors = BepInEx 6 IL2CPP)

Written 2026-09-29 (Off the Clock) from our own work plus the public sources listed at the end (all accessed 2026-09-29). Our setups:
- **Subnautica:** Unity 2019.4 Mono, BepInEx **5.4.23.5** (Tobey's pack 3.1.1), HarmonyX, Nautilus 1.0.0-pre.54, netstandard2.0.
- **BALL x PIT and Vampire Survivors:** Unity 6 IL2CPP, BepInEx **6 bleeding edge be.788**, Il2CppInterop, HarmonyX, net6.0.

Tags: **[OURS]** = learned from our own tests/crashes. **[PUBLIC]** = docs, source, issues or community guides. **[BOTH]** = both.

Short answer: BepInEx is better documented than UE4SS for *installing*, but its developer docs are thin (the patching page itself says "still WIP"). The real rules live in the Harmony docs, the Il2CppInterop and HarmonyX READMEs/wikis, the source code and the BepInEx Discord. The threading story is much simpler than UE4SS: Unity runs our patches on the main thread, so the big risks are **silent failures** (swallowed exceptions, inlined methods, skipped plugins), not races.

---

## 1. One-page checklist

| # | Rule | Why | Source |
|---|---|---|---|
| 1 | **All game/Unity work on the Unity main thread**, from Harmony patches on game methods or a plugin MonoBehaviour's `Update`. No `Task.Run`, `new Thread`, `ThreadPool`, `System.Threading.Timer` or `async void` for game objects. | The Unity API isn't thread-safe. On IL2CPP, a thread not attached with `il2cpp_thread_attach` hits access violations. | [PUBLIC] Unity manual; IL2CPP_Resolver #9; general community knowledge |
| 2 | **Wrap every patch body in try/catch and log once.** Never let an exception leave a patch. | IL2CPP: Il2CppInterop's native->managed trampoline catches it, logs `During invoking native->managed trampoline`, and **returns a default (0/null/false) to the game**, which silently changes game behaviour. Mono: the exception propagates into game code. | [PUBLIC] `Il2CppDetourMethodPatcher.cs` (Il2CppInterop master); [OURS] every plugin already does this |
| 3 | **Fail-safe patching per feature:** resolve each target (`AccessTools`), patch it separately, log one INFO line per applied patch and one WARNING per skipped feature. Never let one missing method kill the whole plugin. | Game updates rename methods. One feature should degrade, not the whole mod. | [OURS] |
| 4 | **Prefer postfixes. Return `false` from a prefix only when you really replace the method, and read `__runOriginal`.** | HarmonyX (what BepInEx ships) runs **all** prefixes even after one returns false. Others' prefixes still run after ours skips, and ours still runs after theirs skips. `__runOriginal` tells you whether the original will run. Upstream Harmony differs, so don't copy its semantics. | [PUBLIC] HarmonyX wiki "Difference between Harmony and HarmonyX"; Harmony docs (prefix) |
| 5 | **IL2CPP: check that a target method is actually called.** Look at the interop `[CallerCount(n)]` attribute. `0` usually means it's inlined or never called, so the patch won't fire. Patch a caller instead, and confirm with a one-time log line. | IL2CPP/C++ inlining removes the call site; Harmony only detours the method body. | [PUBLIC] Harmony "Patching edge cases" (inlining); community guides on CallerCount; BepInEx #598; [OURS] we verify targets by disassembly |
| 6 | **IL2CPP: field accessors can't be patched.** A property on an interop type may really be a field getter. Patch the method that reads or writes it. | Il2CppInterop throws "is a field accessor, it can't be patched". | [PUBLIC] `Il2CppDetourMethodPatcher.cs` |
| 7 | **IL2CPP: avoid patching methods with `ref` struct params or constructors.** | Open HarmonyX/Il2CppInterop bugs: ref params give invalid IL (HarmonyX #93, open since 2023-12), ref struct data gets zeroed (HarmonyX #126, 2025-04), constructors can't be patched (Il2CppInterop #87). | [PUBLIC] |
| 8 | **IL2CPP casting:** use `.Cast<T>()` / `.TryCast<T>()`, never C# `as`/`is` or C-style casts on Il2Cpp objects. Use `Il2CppType.Of<T>()` where IL2CPP wants a `System.Type`. Convert delegates via implicit `System.Action`/`Func` conversion. | Managed wrappers don't carry the IL2CPP runtime type. `as`/`is` checks the wrapper, not the object. | [PUBLIC] Il2CppAssemblyUnhollower README (Il2CppInterop's origin) |
| 9 | **IL2CPP: never call interop getters that return `Nullable<enum>`** (or any `Il2CppSystem.Nullable<T>` of a value type) when the value can be empty. Read the field raw (`il2cpp_field_get_value_object`), or get the answer from another source. | IL2CPP boxes an empty Nullable to a null pointer, and the interop wrapper constructor throws an NRE (Vampire Survivors Unlock All 1.0.0: every base-game entry failed). | [OURS] Vampire Survivors |
| 10 | **IL2CPP: be careful with generics over value types and stripped members.** Methods may be missing, since unstripping is partial. Build against the interop assemblies generated for **this** game build. | "Using generics with value types may lead to exceptions or crashes because of missing method bodies". | [PUBLIC] Il2CppAssemblyUnhollower README |
| 11 | **Injected MonoBehaviours:** `ClassInjector.RegisterTypeInIl2Cpp<T>()` before first use, create them with `AddComponent<T>()` (never `new`), keep them free of self-referencing IL2CPP collections. | Injected instances are owned by the IL2CPP GC. `new` breaks them, and self-references leak forever (the GC can't see across domains). | [PUBLIC] Il2CppInterop `Class-Injection.md`; [OURS] |
| 12 | **Don't hold Unity objects across scene loads.** Test with Unity's `== null` (the "fake null" overload) before each use, and re-find after scene changes. | Destroyed Unity objects compare equal to null but aren't C# null. Their wrappers throw on use. | [PUBLIC] Unity blog "Custom == operator" (2014); community knowledge |
| 13 | **Patch after the game is ready.** Apply patches in `Awake` (BepInEx 5) / `Load` (BepInEx 6), but don't *touch* game singletons there. Wait for a menu/scene hook (e.g. `MainMenuPage.OnShowStart`, `IsInitialized`). | Harmony "Patching too early (Unity)" gives MissingMethodException. Static constructors run on first access. Save data isn't loaded yet. | [BOTH] Harmony edge cases; one of our Vampire Survivors mods waits for `PlayerOptions.IsInitialized` |
| 14 | **Harmony ID = plugin GUID, reverse-domain, unique.** Unpatch only your own patches: `harmony.UnpatchSelf()`, never `Harmony.UnpatchAll()`. | `UnpatchAll()` removes every mod's patches. HarmonyX marks the instance version obsolete. | [PUBLIC] Harmony basics; HarmonyX wiki |
| 15 | **GUID: `^[a-zA-Z0-9._-]+$`, never changes, never reused. Version: a plain `MAJOR.MINOR.PATCH` string.** | BepInEx **skips** plugins whose GUID doesn't match that regex or whose version doesn't parse ("because its version is invalid"). With **duplicate GUIDs only the highest version loads**, and the rest are skipped with a warning. BepInEx 5 uses `System.Version` (numeric only; `1.0.0-beta` = invalid). | [PUBLIC] BepInEx `BaseChainloader.cs` (master) and `Chainloader.cs` (v5-lts) |
| 16 | **One DLL name and one GUID per product, across all your projects.** Never ship an experiment with a released product's assembly name. | Two DLLs with the same GUID: one silently wins. The same file name overwrites on install. | [OURS] (a BALL x PIT experiment once built another product's DLL name) |
| 17 | **Config via `Config.Bind(section, key, default, description)`,** with a real description on every entry, `AcceptableValueRange`/`AcceptableValueList` for numbers and choices, and keys as `KeyCode`/`KeyboardShortcut` entries (never hard-coded). Paths from `BepInEx.Paths`. | The cfg file is the player's UI; descriptions become comments. Configurable keys are a standing rule for us. | [BOTH] BepInEx docs "Configuration"; our key rule |
| 18 | **Keys:** check native binds (Rewired dumps, hard-coded `Input.GetKey` reads) before picking one. **Numpad Enter = Submit** in Unity UI/Rewired maps. BALL x PIT digit rows set game speed (hard-coded). | Key clashes read as "mod broken". | [OURS] |
| 19 | **Honesty and achievements:** use the game's own cheated/modded flags where they exist and never clear them. Never use game cheat modes that disable achievements (Subnautica `GameModeUtils` cheats, `DevConsole`). Switch off in online co-op. | Player trust and fair play. | [OURS] |
| 20 | **Save-writing mods back up the save first,** use the game's own save/backup call, run once (opt-in switch that turns itself off), and log exactly what changed. | Saves are the player's most valuable data. | [OURS] |
| 21 | **Dev cheats in release builds are often stubs.** Verify the body (disassembly) before relying on `ApplyCheat`-style functions. | BALL x PIT `ApplyCheat` is empty in release. | [OURS] |
| 22 | **After every game or loader update:** regenerate interop (IL2CPP: BepInEx does it on start when `UpdateInteropAssemblies = true`) or re-copy refs (Mono), rebuild, then read `LogOutput.log` for skipped patches/plugins. | Stale interop/refs = MissingMethod/TypeLoad errors, or patches on moved methods. | [BOTH] BepInEx.cfg `[IL2CPP]` comments; our Subnautica README |
| 23 | **IL2CPP first run downloads Unity base libraries** from `unity.bepinex.dev` (`UnityBaseLibrariesSource`). Offline or in CI, pre-place the zip in `BepInEx\unity-libs`. | The first start fails or hangs without it; test machines may be offline. | [PUBLIC] BepInEx.cfg comments |
| 24 | **Reproducible builds:** Deterministic, PathMap, no SourceLink/commit hash; warnings as errors. | Byte-identical rebuilds prove that the zip matches the source. | [OURS] |
| 25 | **Vanilla check:** rename the Doorstop proxy (`winhttp.dll`) for one run; loader files are added, never overwritten. | Baseline before blaming a mod. | [OURS] |

---

## 2. Details

### 2.1 BepInEx 5 vs 6 (what changes for us)
| Topic | BepInEx 5 (Subnautica) | BepInEx 6 IL2CPP (BxP, VS) |
|---|---|---|
| Plugin base | `BaseUnityPlugin` (is a MonoBehaviour; `Awake`, `Update` available) | `BasePlugin` (`Load()`; not a MonoBehaviour; get an update loop with `AddComponent<T>()` + `ClassInjector`) |
| Namespaces | `BepInEx`, `BepInEx.Configuration` | `BepInEx.Unity.IL2CPP`, `Il2CppInterop.Runtime.*`, game types from generated interop |
| Game code | real managed `Assembly-CSharp.dll` (decompile with ILSpy) | interop stubs over native `GameAssembly.dll` (read with Cpp2IL/LibCpp2IL dumps and disassembly) |
| Harmony | HarmonyX on managed IL (inlining by Mono JIT is rare but possible) | HarmonyX via Il2CppInterop's native detour: exceptions swallowed (rule 2), field accessors unpatchable, ref-param bugs, inlined callers (rule 5) |
| Version parse | `System.Version` (numeric only) | SemVer `Version.TryParse`, then a System.Version fallback |
| Releases | stable 5.4.23.x (latest v5.4.23.5, 2026-02-08) | only bleeding-edge builds (`be.NNN` on builds.bepinex.dev). The last GitHub pre-release is 6.0.0-pre.2 (2024-08). Pin the exact be number on pages. |

### 2.2 Harmony patching craft
- Patches are **static** methods in a patch class. Use `[HarmonyPatch(typeof(T), nameof(T.M))]` when the interop type is referenced at compile time (a missing type then fails at load, so wrap `PatchAll` in try/catch as one of our mods does), or PatchGuard-style `AccessTools.TypeByName` + `harmony.Patch` for per-feature isolation. [PUBLIC Harmony docs + OURS]
- `__instance`, `__result`, `__state`, `ref` args: in IL2CPP, `__instance` is an interop wrapper, so compare with `==` / `.Pointer`, not reference identity. [PUBLIC community]
- Generic methods share implementations for reference types, so patching one patches all of them. Patch value-type instantiations separately and check `__instance` type args. [PUBLIC Harmony edge cases]
- Transpilers: avoid in IL2CPP (there's no IL for native methods; Il2CppInterop generates a trampoline). On Mono, keep them small and match by opcode + operand, never by index, and fail closed when the pattern isn't found. [PUBLIC Harmony docs]
- Test that a patch can fail: point one scenario at a renamed method and confirm the WARNING line appears (our "break it once" rule). [OURS]

### 2.3 IL2CPP object lifetime and GC
- Managed wrappers of IL2CPP objects hold a GC handle. Injected class instances are **collected by the IL2CPP GC even when managed code still references them**, which gives `ObjectCollectedException`. Keep injected components on live GameObjects, and don't stash them in static fields as the only reference. [PUBLIC Class-Injection.md; Il2CppInterop issue #40 "Injected class fields are collected", open]
- Collections: `Il2CppSystem.Collections.Generic.List<T>`/`Dictionary<K,V>` index with `Count`/`[i]`. Enumerate with index loops when in doubt. `out T` on generic params (`TryGetValue`) was historically broken, so prefer `ContainsKey` + indexer. [PUBLIC Il2CppAssemblyUnhollower README known issues]
- Strings: `string` converts automatically at interop boundaries. `Il2CppSystem.String` appears in some signatures; call `.ToString()`. [PUBLIC]

### 2.4 Logging and diagnosis
- Use the plugin's `ManualLogSource` (`Log`/`Logger`), one startup line with the version, one line per applied patch, and throttle per-frame logs. [OURS]
- `BepInEx\LogOutput.log` signatures to grep after every test: `Skipping type`, `because its version is invalid`, `similar GUID`, `could not patch` / `not found - this part is skipped`, `During invoking native->managed trampoline`, `Exception in IL2CPP-to-Managed trampoline`, `MissingMethodException`, `TypeLoadException`, `ObjectCollectedException`. [PUBLIC source strings + OURS]
- Our IL2CPP evidence path: offline dumps and disassembly before any in-game guessing. [OURS]

### 2.5 Packaging and versioning (Nexus/Vortex)
- Zip root = `BepInEx/plugins/<ModName>/<ModName>.dll` (or `plugins/<ModName>.dll`). Vortex installs cleanly when the archive has a recognisable root folder. Otherwise it asks the player to pick one. [PUBLIC Nexus article "Packaging Mods for Vortex" (site/articles/217)]
- Don't bundle BepInEx or Nautilus in our zips. Link the official pack on the page and name the exact build tested. [OURS + community norm]
- SemVer for players: MAJOR = breaking config/save change, MINOR = new feature/option, PATCH = fix. The same string goes in `PLUGIN_VERSION`, the csproj and the zip name. [PUBLIC semver.org + OURS]
- Soft dependencies (Nautilus menu) via `[BepInDependency(guid, SoftDependency)]` plus a runtime check, so the plugin works without it. [PUBLIC BepInEx attributes + OURS]

---

## 3. Contradictions and cautions in public advice

| Public advice | Where | Our position / evidence |
|---|---|---|
| "Return false to skip the original and **all other prefixes**" | Harmony docs (prefix page) | Wrong for BepInEx: HarmonyX runs all prefixes. Write prefixes that check `__runOriginal`. |
| `harmony.UnpatchAll()` to clean up | Older Harmony tutorials | Removes everyone's patches. Use `UnpatchSelf()` (HarmonyX makes the instance form obsolete). |
| "Patch in Awake and use game objects right away" | Many beginner tutorials | Patch early, act late: wait for a game-ready hook (Harmony "patching too early"; a Vampire Survivors save-not-loaded case). |
| Using `as`/`is` on game types | Mono-era tutorials copied to IL2CPP | Use `TryCast<T>()`/`Cast<T>()` on IL2CPP. |
| Hooking a getter/property "because it's simpler" | common | On IL2CPP it may be a field accessor (unpatchable) or inlined (CallerCount 0). Verify first. |
| Using the game's cheat/dev-console path for effects | common in Subnautica tutorials (console commands) | Disables achievements (`GameModeUtils` cheat mask, `DevConsole.HasUsedConsole`). We use Harmony patches and `NoDamageConsoleCommand` from code instead. [OURS, from decompiled code] |

No public source contradicts a BepInEx rule we already had.

---

## 4. Where to look when stuck

| Source | URL | Good for |
|---|---|---|
| BepInEx source (master = 6, `v5-lts` = 5) | https://github.com/BepInEx/BepInEx | Exact loader behaviour: chainloader skip rules, config, IL2CPP bootstrap. `Runtimes/Unity/BepInEx.Unity.IL2CPP/` for IL2CPP |
| BepInEx docs | https://docs.bepinex.dev/master/ (install guides, plugin tutorial, config) | Installation per runtime, plugin skeleton, config API. Thin on patching. |
| BepInEx bleeding-edge builds | https://builds.bepinex.dev/projects/bepinex_be | Which `be.NNN` is current; the changelog per build |
| BepInEx issues | https://github.com/BepInEx/BepInEx/issues | Unity 6 / new-Unity breakage (e.g. #1312, #1314 on Unity 6000), IL2CPP start-up crashes |
| Il2CppInterop | https://github.com/BepInEx/Il2CppInterop (docs in `/Documentation`: Class-Injection, Implementing-Interfaces) + issues | Class injection, GC caveats, patch backend (`Il2CppInterop.HarmonySupport/Il2CppDetourMethodPatcher.cs`), known bugs (#40, #87, #235, #239) |
| Il2CppAssemblyUnhollower README (archived origin) | https://github.com/knah/Il2CppAssemblyUnhollower | The clearest list of IL2CPP usage rules and known limitations (Cast/TryCast, Il2CppType.Of, generics, delegates) |
| HarmonyX wiki + issues | https://github.com/BepInEx/HarmonyX/wiki , https://github.com/BepInEx/HarmonyX/issues | BepInEx-specific Harmony semantics (`__runOriginal`, `UnpatchSelf`, logging); IL2CPP patch bugs (#93, #126) |
| Harmony docs | https://harmony.pardeike.net/articles/intro.html (esp. `patching-edgecases.html`, `patching-prefix.html`, `basics.html`) | Patch types, injections, edge cases (inlining, generics, too-early patching, static ctors) |
| BepInEx Discord | linked from https://github.com/BepInEx/BepInEx README | Fastest answers from maintainers (IL2CPP interop questions especially). |
| Subnautica: Nautilus docs + SN Modding Discord | https://subnauticamodding.github.io/Nautilus/ ; https://github.com/SubnauticaModding/Nautilus | Options menus, items, "latest game version only" support policy |
| Tobey's BepInEx pack | https://github.com/toebeann/BepInEx.Subnautica | The Subnautica loader players use; its cfg defaults (e.g. `HideManagerGameObject = true`) |
| Nexus packaging | https://www.nexusmods.com/site/articles/217 ; https://github.com/Nexus-Mods/Vortex/wiki | Vortex-friendly archive layout |

---

## 5. Keeping this checklist current

1. **Loader builds:** compare the newest `be.NNN` on builds.bepinex.dev with the one you build against, read `gh api repos/BepInEx/BepInEx/commits?since=<last>` for anything touching IL2CPP, the chainloader or detours, and check the BepInEx 5 releases.
2. **Interop/Harmony:** Il2CppInterop and HarmonyX releases and new issues (`gh api -X GET search/issues -f q='repo:BepInEx/Il2CppInterop is:issue created:>=<last>'`, same for HarmonyX).
3. **Per game:** Nautilus releases (Subnautica), Tobey pack releases, and game patch notes. A game update means regenerate interop, rebuild, then scan the log.
4. **Record** new pitfalls here with date, source and tag. Never auto-update a player-facing requirement; plan a test session first.
