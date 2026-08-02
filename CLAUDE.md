# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. The authoritative architecture and workflow document is `AGENTS.md` — prefer it for render-path, module-boundary, and state/UI-trap details. This file is the code-navigation entry point; keep the two consistent.

## Project

mcrysden is a native macOS crystal/molecule viewer — a from-scratch Swift/Metal reimagining of XCrySDen 1.6.2. It reads structure files (XSF, AXSF, XYZ, PDB, CIF, POSCAR/VASP, Quantum Espresso PWscf input/output, Gaussian Cube, BXSF, WIEN2k, CRYSCAL, ORCA, FHI-aims) plus QE band structures and DOS tables, and renders crystals and molecules interactively via Metal, plus headless PNG and raster-backed PDF/SVG/EPS/PS export. macOS 14+ (Sonoma), Apple Silicon or Intel.

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

Force the parser (overrides extension-based dispatch): `--xsf --axsf --xyz --pdb --pwi --pwo --cif --poscar --cube --bxsf --struct --crystal --orca --fhi --bands --dos`. Parser chosen by extension otherwise. `.out` is ambiguous — `ParseFormat.from(url:)` sniffs QE, ORCA, and FHI-aims content (QE checked first); standard QE projected-DOS names like `.pdos_atm#...` match by full filename, not only `pathExtension`.

**GUI controls** (SwiftUI `SideBar`): Display-mode picker, atom-scale / bond-radius sliders, Cell Frame + Axes toggles, BG hex, Supercell steppers, Slab h/k/l, animation playback, Structure Summary, k-path editor, atom table, coordination analysis, command palette, and a **Reset View** button (top of sidebar) that reframes the camera — center on centroid, distance fit to bounding sphere, rotation cleared.

**Menu bar** (programmatic `NSMenu` built in `App.swift`): **File** (Open `⌘O`, Save State As, Export, Revert To Saved, Open Recent), **Edit** (standard undo/redo/cut/copy/paste/select-all routed to first responder + Copy Current View to clipboard), **View** (Toggle Element Labels `⌘L`, display toggles), **Window** (multi-structure windows).

**Orientation gizmo** (`Renderer.drawOrientationGizmo`): when the Axes toggle is on, a fixed-size triad of bold arrows (shaft + head, real triangle geometry) is pinned to the **bottom-left corner** of the viewport. It shows the world **x/y/z axes in red/green/blue**, rotates as you orbit, but never scales with zoom (NDC-space, identity view+proj). Drawn last with depth disabled so it overlays the scene, for both crystals and molecules.

Local install: `swift build -c release && cp .build/release/mcrysden /usr/local/bin/`

## Tests

XCTest, under `Sources/MolVisAppTests` (not the empty top-level `Tests/`). Access via `@testable import MolVisApp`.

- **Unit tests** — Parser, Scene, StateStore, Renderer, Model, ElementTable, and many more.
- **Snapshot tests** — `SnapshotTests` extends `Snapshotter`, renders a fixed scene+camera to a 64×64 texture, compares an FNV-1a pixel hash against committed goldens in `Sources/MolVisAppTests/Fixtures/golden/`. Regenerate goldens with env var `MCRYSDEN_REGENERATE=1`.
- **Integration / regression tests** — scene and format loading, renderer/export behavior, state persistence, HPKOT oracle validation, periodic measurements, and animation-frame lifecycle behavior.

The tracked suite contains **98 tests**. Keep the suite at no more than 100 focused tests; replace lower-value cases when adding higher-value coverage.

Fixtures live in `Sources/MolVisAppTests/Fixtures/` and are loaded at runtime via `#file`-relative paths. CI runs on `macos-14` (Apple Silicon) via `.github/workflows/ci.yml`.

## Architecture

Four production SPM targets plus the `MolVisAppTests` test target (`Package.swift`):

- **`MolEnvParse`** — C-only (`Sources/MolEnvParse/`). Exposes `parse_xsf`, `parse_axsf` (frame-indexed), `parse_xyz`, `parse_pdb`, `parse_cif`, each returning a heap-allocated `MolEnvScene*`. Also bond detection via a covalent-radii distance heuristic. Swift copies the returned data into value types, then calls `molenv_scene_free` — no C pointer is held across an async boundary.
- **`SpglibCore`** — vendored spglib 2.7.0 (`Sources/SpglibCore/`).
- **`MolEnvSpglib`** — Swift/C façade over SpglibCore (`Sources/MolEnvSpglib/`) for space-group analysis.
- **`MolVisApp`** — everything else: process lifecycle, window, renderer, scene model, state, export, camera. Never calls the C parser directly; routes through a Swift wrapper (`Parser.swift`).
- **`MolVisAppTests`** — test target.

### Critical design invariant

`Renderer.encode(to commandBuffer:, target: MTLTexture, viewport:, camera:)` takes the **target texture as a parameter**. This single code path drives both on-screen MTKView rendering and offscreen PNG/vector export — it is the central design decision and must be preserved. Headless `PngExporter` / `VectorExporter` own their own `MTKView`-free `MTLTexture`; live rendering uses the view's current drawable. Don't hardcode either.

The compiled Metal source is the `Renderer.shaderSource` string in `Renderer.swift`. `Package.swift` explicitly excludes `Shaders.metal`; editing that file alone has no runtime effect. `FrameData` must remain byte-layout-compatible with its Metal declaration — Swift `SIMD3<Float>` and Metal `float3` struct fields occupy 16-byte slots.

Lighting azimuth/elevation is camera-relative. `Renderer.makeFrame` converts it to world space each frame; the corner orientation-gizmo arrows are transformed into camera space before lighting. Do not reintroduce a light vector that rotates with the model.

Graph views (`BandGrapherView`, `DOSGrapherView`, `ColorPlaneView`) are viewport siblings of the Metal canvas. Hiding the canvas must not hide the selected graph.

### Data flow

- **GUI:** argv → `App.applicationDidFinishLaunching` → `Parser.load` (C → Swift snapshot) → `Scene` → `MainWindowController` → `Renderer` → `MTKView` (SwiftUI `SideBar` mutates `Scene` via `SideBarState` → `syncFromState()`).
- **Headless:** argv → scene parse → optional `StateStore.load` → `PngExporter.export` / `VectorExporter.export` (offscreen texture → image → PNG/PDF/SVG/EPS/PS) → `NSApp.terminate(nil)` on success, `exit(EXIT_FAILURE)` on error. No window is created. `main.swift` explicitly installs the `NSApplicationDelegate`; replacing it with a conventional `@main` delegate can leave the headless path hanging because this SwiftPM executable has no nib or Info.plist.

### Key types

- `Scene` (struct, `Codable`) — atoms, bonds, optional cell, display mode, supercell, slab, view flags. Value type so it's cheap to snapshot for state save.
- `Camera` (struct) — `center`, `distance`, `rotation: simd_quatf`, `projectionPerspective` (orthographic by default). **View state, not scene state** — it is NOT serialized in the state file by default; reopening a file reframes the view.
- `DisplayMode` — `.ballStick`, `.spaceFill`, `.wireFrame`, `.polyhedral`, plus 2D line / 2D point / 2D ball-stick. All 3D modes render via **instancing** (one `drawPrimitives(instanceCount:)` per geometry type; sphere/cylinder meshes pre-tessellated once, per-instance buffers carry position/radius/color).
- `ElementTable` — static lookup by atomic number (CPK colors + covalent/vdW radii + atomic masses, Z=0..118), compiled in as an array literal.

### Module layout (Sources/MolVisApp/)

| File | Role |
|------|------|
| `main.swift` | Entry; installs `NSApplicationDelegate` (see headless invariant) |
| `App.swift` | CLI parsing, GUI/headless startup, menu bar, export dispatch, canonical format table, app version |
| `Parser.swift` | C-to-Swift bridge, format detection, all loaders |
| `Scene+Init.swift` | `LoadedScene` → `Scene` conversion, supercell/slab; calls C bond heuristic when rebonding |
| `Model.swift` | `Scene`, `Atom`, `Cell`, `Camera`, display enums |
| `ElementTable.swift` | CPK colors, covalent/vdw radii, atomic masses |
| `Geometry.swift` | Mesh generators (spheres, cylinders, polyhedron faces) |
| `Camera.swift` | Matrix math |
| `Renderer.swift` | Metal renderer: atoms, bonds, cell, axes, BZ, isosurfaces, k-path; contains embedded shader source |
| `Renderer2D.swift` | Metal 2D primitives |
| `MetalView.swift` | MTKView + responder events → camera; `NSTrackingArea` hover |
| `MainWindowController.swift` | Window, sidebar, viewport, playback, state sync, coordination, measurements |
| `SideBar.swift` | SwiftUI sidebar: display, k-path, supercell, slab, animation, structure summary, atom table, coordination |
| `SideBarState.swift` | `ObservableObject`: all `@Published` fields; `onChange` fires synchronously from `didSet` |
| `StateStore.swift` | `.mvis-state` JSON serialization |
| `PngExporter.swift` | Headless offscreen PNG export |
| `VectorExporter.swift` | Raster-backed PDF/SVG/EPS/PS export |
| `ExportOptions.swift` / `ExportOptionsView.swift` | Configurable export dimensions, background, transparency |
| `StructureSummary.swift` | Lattice, composition, density, symmetry data model |
| `AtomTableView.swift` | Virtualized read-only atom table (Cartesian/fractional, filtering, linked selection) |
| `ReadoutView.swift` | Bottom-docked selection/measurement readout panel |
| `LabelOverlayView.swift` | AppKit element-label overlay (atom/routeNode/tooltip styles) |
| `CommandPaletteView.swift` | Searchable command palette |
| `CoordinationAnalysis.swift` | Periodic image-aware coordination shells/CN, neighbor readout |
| `PeriodicGeometry.swift` | Skew-cell-safe minimum-image displacement, periodic measurements |
| `Reciprocal.swift` | Reciprocal lattice, scale-safe Double math, G-star enumeration |
| `BrillouinZone.swift` | BZ polyhedron construction, caching, centering detection |
| `CrystalSymmetry.swift` | Spglib analysis: space group, Wyckoff, standardized cells |
| `HPKOT.swift` | SeekPath 2.1 canonical paths for all 29 Bravais variants |
| `KPath.swift` | k-path interpolation, QE/KPF/VASP export |
| `CanonicalPathGenerator.swift` | High-symmetry path generation |
| `BandStructure.swift` | QE band structure + uniform-mesh detection |
| `BandAnalysis.swift` | Band-analysis engine: VBM/CBM, gap, metallicity, effective masses |
| `DensityOfStates.swift` | QE total/projected DOS tables |
| `DOSAnalysis.swift` | DOS-analysis engine: band center, width, gap estimate, spin moment, electron-count consistency |
| `ElectronicAnalysisPresentation.swift` | Band/DOS analysis readout, unavailable-state formatting, and text/CSV payloads |
| `ForceParser.swift` | Force/energy/stress data parsing |
| `Isosurface.swift` | 3D isosurface generation + caching (Marching Cubes) |
| `MarchingCubesTables.swift` | Marching Cubes edge/triangle tables |
| `BandGrapherView.swift` | Band structure graph view |
| `DOSGrapherView.swift` | DOS graph view |
| `ColorPlaneView.swift` | 2D color-plane / contour view |

## Error handling principles

Never crash on malformed input; never silently swallow errors.

- Parser: returns `nil` on failure, writes reason to thread-local `molenv_last_error`; Swift wraps as `ParseError { path, line, reason }`. I/O errors caught on the Swift side before calling C.
- Renderer: shader compile/link failures caught at construction (once at launch), surfaced as fatal. Supercell OOM bounded by a 500k-atom cap — requests beyond it are refused non-fatally, scene unchanged.
- State load: missing keys → defaults; unknown `displayMode` → `.ballStick` + console log; `version > 1` → non-fatal alert, abort load; invalid numbers → clamped + console warning.

## State and UI traps

- `Scene` is a value snapshot; `MainWindowController` owns the live `Camera`. State files may optionally serialize a camera, but opening without one reframes the view.
- `SideBarState` properties call `onChange` synchronously from `didSet`. Mirroring values back into state can recurse; preserve `isSyncingState`, and set `isReloadingFrame` before assigning `state.frameIndex`.
- Controller tests must use `MainWindowController(scene: ..., showWindow: false)`. Presenting and closing a real AppKit window in XCTest leaves asynchronous `_NSWindowTransformAnimation` teardown that can crash later tests.
- Supercell expansion is refused above `Scene.superCellAtomCap` (500,000 atoms); keep failure non-fatal and leave the scene unchanged.

## Code style

No linter configured (no SwiftLint). Match existing conventions: 4-space indent; value types (`struct`) for model data; `enum`s for namespaced constants (`ElementTable`, `Geometry`, `Parser`, `PngExporter`, `StateStore`, `ParseError`, `RenderError`); `final class` for renderers/controllers; heavy inline documentation referencing spec sections and review findings.

## Design references

The authoritative architecture and workflow document is **`AGENTS.md`** — read it before making decisions that affect the render path, module boundaries, the C→Swift bridge, or state/UI lifecycle. Other references:

- `docs/superpowers/specs/2026-07-06-mcrysden-design.md` — original render and bridge design; predates several implemented formats and UI features, so prefer `Package.swift`, CI, scripts, and current source when it conflicts.
- `docs/ROADMAP.md` — authoritative feature-status document. Update it after each implementation commit.
- `CHANGELOG.md` — follows Keep a Changelog. Add entries for each released version.
- `docs/SYMMETRY_AND_KPATH.md` — documents the symmetry and canonical-path contract.
