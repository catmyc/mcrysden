# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project

mcrysden is a native macOS crystal/molecule viewer — a from-scratch Swift/Metal reimagining of XCrySDen 1.6.2. It reads structure files (XSF, AXSF, XYZ, PDB, and Quantum Espresso PWscf `.pwi`/`.in`/`.inp`) and renders crystals and molecules interactively via Metal, plus a headless PNG export mode. macOS 14+ (Sonoma), Apple Silicon or Intel.

## Build & Run (SPM only — there is no .xcodeproj)

```bash
swift build                       # debug build
swift build -c release            # release build
swift run mcrysden                    # empty viewer
swift run mcrysden file.xsf           # open a structure
swift run mcrysden file.xsf state.mvis-state           # apply saved state
swift run mcrysden file.xsf state.mvis-state --export out.png  # headless render
swift test                        # run all tests
swift test --filter SceneTests/testXSFHappyPath   # run a single test
zsh scripts/smoke.sh              # CI smoke test (release build + headless export)
```

Force the parser (overrides extension-based dispatch): `--xsf` `--xyz` `--pdb` `--axsf` `--pwi`. Parser chosen by extension otherwise: `.xsf` `.axsf` `.xyz` `.pdb` `.pwi` `.in` `.inp`.

**GUI controls** (SwiftUI `SideBar`): Display-mode picker, atom-scale / bond-radius sliders, Cell Frame + Axes toggles, BG hex, Supercell steppers, Slab, and a **Reset View** button (top of sidebar) that reframes the camera — center on centroid, distance fit to bounding sphere, rotation cleared.

**Menu bar** (programmatic `NSMenu` built in `App.swift`): **File > Open...** (`⌘O`) presents an `NSOpenPanel` filtered to supported structure-file extensions; **View > Toggle Element Labels** (`⌘L`) toggles `scene.showLabels`, which projects each atom to screen coordinates and draws its element symbol via `LabelOverlayView` (AppKit `NSString.draw` — no Metal text pipeline needed).

**Orientation gizmo** (`Renderer.drawOrientationGizmo`): when the Axes toggle is on, a fixed-size triad of bold arrows (shaft + head, real triangle geometry) is pinned to the **bottom-left corner** of the viewport. It shows the world **x/y/z axes in red/green/blue**, rotates as you orbit, but never scales with zoom (NDC-space, identity view+proj). It's drawn last with depth disabled so it overlays the scene, and it renders for both crystals and molecules (no longer gated on a unit cell).

Local install: `swift build -c release && cp .build/release/mcrysden /usr/local/bin/`

## Tests

XCTest, under `Sources/MolVisAppTests` (not the empty top-level `Tests/`). Access via `@testable import MolVisApp`.

- **Unit tests** — Parser, Scene, StateStore, Renderer, Model, ElementTable.
- **Snapshot tests** — `SnapshotTests` extends `Snapshotter`, renders a fixed scene+camera to a 64×64 texture, compares an FNV-1a pixel hash against committed goldens in `Sources/MolVisAppTests/Fixtures/golden/`. Regenerate goldens with env var `MCRYSDEN_REGENERATE=1`.
- **Diagnostic tests** — `DiagnosticTests`, `CellRenderDiag`, `DragSignTest` render real pixels and assert spatial invariants (e.g. atoms sit inside the cell-frame bounding box).

Fixtures live in `Sources/MolVisAppTests/Fixtures/` and are loaded at runtime via `#file`-relative paths. CI runs on `macos-14` (Apple Silicon) via `.github/workflows/ci.yml`.

## Architecture

Three SPM targets (`Package.swift`):

- **`MolEnvParse`** — C-only (`Sources/MolEnvParse/`). Exposes `parse_xsf`, `parse_axsf` (frame-indexed), `parse_xyz`, `parse_pdb`, each returning a heap-allocated `MolEnvScene*`. Also bond detection via a covalent-radii distance heuristic. Swift copies the returned data into value types, then calls `molenv_scene_free` — no C pointer is held across an async boundary.
- **`MolVisApp`** — everything else: process lifecycle, window, renderer, scene model, state, export, camera. Never calls the C parser directly; routes through a Swift wrapper (`Parser.swift`).
- **`MolVisAppTests`** — test target.

### Critical design invariant

`Renderer.encode(to commandBuffer:, target: MTLTexture, viewport:, camera:)` takes the **target texture as a parameter**. This single code path drives both on-screen MTKView rendering and offscreen PNG export — it is the central design decision and must be preserved. Headless `PngExporter` owns its own `MTKView`-free `MTLTexture`; live rendering uses the view's current drawable. Don't hardcode either.

### Data flow

- **GUI:** argv → `App.applicationDidFinishLaunching` → `Parser.load` (C → Swift snapshot) → `Scene` → `MainWindowController` → `Renderer` → `MTKView` (SwiftUI `SideBar` mutates `Scene` via `SideBarState` → `syncFromState()`).
- **Headless:** argv → scene parse → optional `StateStore.load` → `PngExporter.export` (offscreen texture → CGImage → PNG) → `exit(0)`. No window is created.

### Key types

- `Scene` (struct, `Codable`) — atoms, bonds, optional cell, display mode, supercell, slab, view flags. Value type so it's cheap to snapshot for state save.
- `Camera` (struct) — `center`, `distance`, `rotation: simd_quatf`, `projectionPerspective`. **View state, not scene state** — it is NOT serialized in the state file; reopening a file resets the view.
- `DisplayMode` — `.ballStick`, `.spaceFill`, `.wireFrame`, `.polyhedral`. All render via **instancing** (one `drawPrimitives(instanceCount:)` per geometry type; sphere/cylinder meshes pre-tessellated once, per-instance buffers carry position/radius/color).
- `ElementTable` — static lookup by atomic number (CPK colors + covalent/vdW radii, Z=0..118), compiled in as an array literal.

### Module layout (Sources/MolVisApp/)

`main.swift` (entry), `App.swift` (NSApp delegate + `--export` early-exit), `Model.swift`, `Parser.swift` (C→Swift bridge), `Renderer.swift` (Metal, contains embedded shader source), `Renderer2D.swift` (orthographic swap-in for 2D modes), `MetalView.swift` (MTKView + responder events → camera), `MainWindowController.swift` (NSWindow/NSSplitView owner), `SideBar.swift` + `SideBarState.swift` (SwiftUI), `StateStore.swift` (`.molvis-state` JSON), `PngExporter.swift`, `ElementTable.swift`, `Geometry.swift` (mesh generators), `Camera.swift` (matrix math), `Scene+Init.swift` (init, boundingSphere, widenSuperCell, applySlab).

## Error handling principles

Never crash on malformed input; never silently swallow errors.

- Parser: returns `nil` on failure, writes reason to thread-local `molenv_last_error`; Swift wraps as `ParseError { path, line, reason }`. I/O errors caught on the Swift side before calling C.
- Renderer: shader compile/link failures caught at construction (once at launch), surfaced as fatal. Supercell OOM bounded by a 500k-atom cap — requests beyond it are refused non-fatally, scene unchanged.
- State load: missing keys → defaults; unknown `displayMode` → `.ballStick` + console log; `version > 1` → non-fatal alert, abort load; invalid numbers → clamped + console warning.

## Code style

No linter configured (no SwiftLint). Match existing conventions: 4-space indent; value types (`struct`) for model data; `enum`s for namespaced constants (`ElementTable`, `Geometry`, `Parser`, `PngExporter`, `StateStore`, `ParseError`, `RenderError`); `final class` for renderers/controllers; heavy inline documentation referencing spec sections and review findings.

## Design reference

The authoritative architecture doc is `docs/superpowers/specs/2026-07-06-mcrysden-design.md` — read it before making decisions that affect the render path, module boundaries, or the C→Swift bridge.
