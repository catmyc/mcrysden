# AGENTS.md

## Workflow: Implement-Review-Fix Loop

For multi-component features, dispatch independent **Longcat subagents** in parallel, review their combined output, fix findings, and repeat until clean. Use DeepSeek subagents only if Longcat fails mid-task (token-insufficient). Do **not** write `edit`/`write`/`apply_patch` calls yourself for feature work — always use subagents.

1. **Dispatch** — Break the feature into file-disjoint slices (e.g., model + UI + wiring). Launch Longcat agents concurrently via `Task(tool)`, each with a crisp, file-constrained prompt and the exact APIs it may depend on.
2. **Review** — When all agents finish, launch a **review subagent** to inspect the combined diff. It reports only actionable findings with severity, file:line, and fix.
3. **Fix** — Dispatch the findings back to Longcat agents (group related findings into the same agent to minimize context). Apply trivial/mechanical fixes directly if faster.
4. **Repeat** — Re-run review after each fix round until the reviewer responds exactly `no actionable findings`.
5. **Verify** — Run `swift build`, `swift test`, and `zsh scripts/smoke.sh`. Commit with a version bump.
6. **Record** - update documentation at the end of the completed work flow. 


Key rules:
- Never dispatch overlapping file scopes to parallel agents.
- If a Longcat task returns empty, re-read the target files to see if it completed silently, then decide whether to re-dispatch or fix directly.
- Remove diagnostic/development-only tests after features stabilize.
- Update `CHANGELOG.md` and `docs/ROADMAP.md` after each commit that implements a roadmap item.

## Platform And Verification

- This is a macOS 14+ SwiftPM executable; there is no Xcode project and Metal/AppKit tests require macOS with a Metal device.
- CI runs these commands in order on `macos-14`:
  ```bash
  swift build
  swift test
  zsh scripts/smoke.sh
  ```
- Run one XCTest with `swift test --filter SceneTests/testXSFHappyPath`.
- `scripts/smoke.sh` performs a release build and headless export to `/tmp/mcrysden_smoke.png`; use it after render, export, CLI, or release-build changes.
- There is no lint, formatter, typecheck, codegen, or dependency-install step beyond SwiftPM.

## Package Boundaries

- `Package.swift` defines three targets: C parser/bond library `MolEnvParse`, executable `MolVisApp`, spglib façade `MolEnvSpglib`, and tests at `Sources/MolVisAppTests` (not `Tests/`). Vendored spglib 2.7.0 lives in `Sources/SpglibCore`.
- `Sources/MolVisApp/main.swift` explicitly installs the `NSApplicationDelegate`. Replacing it with a conventional `@main` delegate can leave the headless export path hanging because this SwiftPM executable has no nib or Info.plist.
- `App.swift` owns CLI parsing, GUI/headless startup, export dispatch, the canonical format table, and the app version string. Add a force-format flag there and matching `ParseFormat` dispatch together.
- `Parser.swift` is the main C-to-Swift bridge and also hosts Swift-only loaders. Copy `MolEnvScene` data into Swift values and free C allocations synchronously; do not retain C pointers across callbacks or async work. `Scene+Init.swift` is the intentional exception that calls the C bond heuristic when rebonding transformed structures.
- `.out` is ambiguous: `ParseFormat.from(url:)` sniffs QE, ORCA, and FHI-aims content, with QE checked first. Standard QE projected-DOS names such as `.pdos_atm#...` are matched by full filename, not only `pathExtension`.

## Render Invariants

- Preserve `Renderer.encode(to:target:viewport:camera:)` as the single render path. Live `MTKView`, offscreen PNG, and raster-backed PDF/SVG/EPS/PS exports supply different target textures to it.
- The compiled Metal source is the `Renderer.shaderSource` string in `Renderer.swift`. `Package.swift` explicitly excludes `Shaders.metal`; editing that file alone has no runtime effect.
- `FrameData` must remain byte-layout-compatible with its Metal declaration. In particular, Swift `SIMD3<Float>` and Metal `float3` struct fields occupy 16-byte slots.
- Lighting azimuth/elevation is camera-relative. `Renderer.makeFrame` converts it to world space each frame; the corner orientation-gizmo arrows are transformed into camera space before lighting. Do not reintroduce a light vector that rotates with the model.
- Graph views (`BandGrapherView`, `DOSGrapherView`, `ColorPlaneView`) are viewport siblings of the Metal canvas. Hiding the canvas must not hide the selected graph.

## State And UI Traps

- `Scene` is a value snapshot; `MainWindowController` owns the live `Camera`. State files may optionally serialize a camera, but opening without one reframes the view.
- `SideBarState` properties call `onChange` synchronously from `didSet`. Mirroring values back into state can recurse; preserve `isSyncingState`, and set `isReloadingFrame` before assigning `state.frameIndex`.
- Controller tests must use `MainWindowController(scene: ..., showWindow: false)`. Presenting and closing a real AppKit window in XCTest leaves asynchronous `_NSWindowTransformAnimation` teardown that can crash later tests.
- Supercell expansion is refused above `Scene.superCellAtomCap` (500,000 atoms); keep failure non-fatal and leave the scene unchanged.

## Key Modules

| File | Role |
|------|------|
| `App.swift` | CLI, GUI lifecycle, menu bar, export dispatch |
| `Parser.swift` | C-to-Swift bridge, format detection, all loaders |
| `Model.swift` | `Scene`, `Atom`, `Cell`, `Camera`, display enums |
| `Scene+Init.swift` | `LoadedScene` → `Scene` conversion, supercell/slab |
| `MainWindowController.swift` | Window, sidebar, viewport, playback, state sync |
| `SideBar.swift` | SwiftUI sidebar: display, k-path, supercell, slab, animation, structure summary |
| `SideBarState.swift` | `ObservableObject` state: all `@Published` fields, route editing |
| `Renderer.swift` | Metal renderer: atoms, bonds, cell, axes, BZ, isosurfaces, k-path |
| `Renderer2D.swift` | Metal 2D primitives |
| `KPath.swift` | k-path interpolation, QE/KPF/VASP export |
| `CrystalSymmetry.swift` | Spglib analysis: space group, Wyckoff, standardized cells |
| `HPKOT.swift` | SeekPath 2.1 canonical paths for all 29 Bravais variants |
| `StateStore.swift` | `.mvis-state` JSON serialization |
| `StructureSummary.swift` | Lattice, composition, density, symmetry data model |
| `ElementTable.swift` | CPK colors, covalent/vdw radii, atomic masses |

## Tests And Fixtures

- Fixtures are loaded from `Sources/MolVisAppTests/Fixtures` using `#file`-relative URLs; do not assume the process working directory inside tests.
- Snapshot tests render 64x64 Metal textures and compare FNV-1a hashes in `Fixtures/golden`. Regenerate intentional visual changes with:
  ```bash
  MCRYSDEN_REGENERATE=1 swift test --filter SnapshotTests
  ```
  Review the changed hashes, then rerun snapshots without the environment variable.
- The tracked suite contains 1053 tests as of v1.1.25. Remove diagnostic/development-only tests after features stabilize; keep only tests that exercise unique production paths.
- Parser failures must become `ParseError` with a useful path/reason; malformed user files must not trap. C parsers report details through thread-local `molenv_last_error`.

## References

- `docs/superpowers/specs/2026-07-06-mcrysden-design.md` explains the original render and bridge design, but it predates several implemented formats and UI features. Prefer `Package.swift`, CI, scripts, and current source when it conflicts.
- `docs/ROADMAP.md` is the authoritative feature-status document. Update it after each implementation commit.
- `CHANGELOG.md` follows Keep a Changelog. Add entries for each released version.
- `docs/SYMMETRY_AND_KPATH.md` documents the symmetry and canonical-path contract.
