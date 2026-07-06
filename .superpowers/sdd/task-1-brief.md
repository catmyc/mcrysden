# Task 1 — SPM skeleton + CLI bootstrap

**Plan:** `/Users/mao/dev/mcrysden/docs/superpowers/plans/2026-07-06-mcrysden.md`
**Report file (return your full report here):** `/Users/mao/dev/mcrysden/.superpowers/sdd/task-1-report.md`

## What you're building

The very first commit of mcrysden — a Swift Package Manager skeleton plus a minimal `@main NSApplication` delegate that parses `--help` / `--export` / file arguments from the terminal and routes to "GUI" vs "headless" paths. No window yet, no renderer yet. The C parser target `MolEnvParse` is created as an SPM `CLibrary` target but contains only a placeholder `#error` that you then remove, to prove the target is wired.

## Files to create

- `Package.swift`
- `Sources/MolVisApp/main.swift`
- `Sources/MolVisApp/MolVisApp.swift` (NSApplicationDelegate, dispatch stub)
- `.gitignore`
- `Sources/MolEnvParse/placeholder.c` (`#error "parser not implemented yet"`, removed in Step 7)

## Steps (verbatim from the plan — follow in order)

Step 1 — Author `Package.swift` (full code in plan Task 1 Step 1). Package name `mcrysden`, platforms `.macOS(.v14)`, executable product `mcrysden`. Three targets: `MolEnvParse` (CLibrary, `path: Sources/MolEnvParse`, `publicHeadersPath: "include"`, cSettings `unsafeFlags(["-fno-modules"])`), `MolVisApp` (executableTarget, depends on MolEnvParse, link AppKit/Metal/MetalKit/SwiftUI), `MolVisAppTests` (testTarget, depends on MolVisApp, `path: Sources/MolVisAppTests`).

Step 2 — Author `Sources/MolVisApp/main.swift` (full code: `@main` shared NSApplicationMain trampoline).

Step 3 — Author `Sources/MolVisApp/MolVisApp.swift` (full code: `class App: NSObject, NSApplicationDelegate` with `applicationDidFinishLaunching` printing `[mcrysden] launched; args=...` and a `printHelp` static that prints the exact Usage block in the plan).

Step 4 — `mkdir -p Sources/MolEnvParse/include` and write `Sources/MolEnvParse/placeholder.c` with `#error "parser not implemented yet"`.

Step 5 — Author `.gitignore` (full code in plan).

Step 6 — `cd /Users/mao/dev/mcrysden && swift build` → confirm the `#error` fires (proves target wiring), then Step 7: delete placeholder.c and rebuild → `Build complete!`.

Step 8 — `swift run mcrysden --help` → prints the Usage block.

Step 9 — Commit: `git add -A && git commit -m "chore: SPM skeleton + CLI bootstrap"`.

## Global constraints (binding)

- macOS 14 (Sonoma) minimum deployment target; Swift 5.9 / Xcode 15+.
- No third-party Swift packages. The C parser module uses only libc.
- Executable name: `mcrysden`.
- Every task commits at the end; every task has a green-test gate before the commit (Task 1 has no unit tests, so the `swift build` + `swift run mcrysden --help` smoke gate replaces it).

## Interfaces this task produces (later tasks depend on these)

- `App.didFinishLaunching(_:)` logs `[mcrysden] launched; args=...` and routes `--help` to `printHelp()` + terminate.
- `App.printHelp()` emits the exact Usage block in the plan.
- `MolEnvParse` target is reachable as a CLibrary (verified: build succeeds after placeholder removal).
- `main.swift` is the `@main` trampoline calling `NSApplicationMain`.

## Report contract

Write your report to the report file above. Return status as one of: DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT, BLOCKED. Include: commits made (sha + message), test/smoke output (the `swift build` and `swift run mcrysden --help` lines), and any deviations or concerns.
