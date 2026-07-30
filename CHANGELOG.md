# Changelog

All notable changes to mcrysden will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.28] — 2026-07-30

### Added

- Electronic-analysis presentation in the sidebar for band VBM/CBM, gap type, metallicity, and effective masses, plus DOS center, width, gap estimate, spin moment, and electron-count consistency. Every metric reports available, unavailable, or insufficient-data status explicitly.
- Concise text and RFC 4180 CSV export for the displayed band or DOS analysis.
- Linked VBM/CBM markers on band plots and estimated DOS gap-edge markers on DOS plots, including exported graphs.

### Tests

- Added presentation, controller-integration, malformed-data, CSV, and graph-marker coverage. Full suite now contains 1173 tests.

### Documentation

- Reconciled `docs/ROADMAP.md`, `CLAUDE.md`, `AGENTS.md`, and `docs/SYMMETRY_AND_KPATH.md` with the current codebase, including package boundaries, headless termination, coordination status, reciprocal-editor contracts, electronic-analysis presentation, and the 1173-test suite.

## [1.1.27] — 2026-07-30

### Added
- Electronic-structure analysis: `BandAnalysis` (VBM/CBM, direct/indirect band gap with band-crossing metallicity detection, effective mass via nonuniform finite differences) and `DOSAnalysis` (band center/width, gap estimate with interpolated threshold-crossing edges, spin moment, electron-count consistency). Interactive band/DOS grapher controls: energy window, Fermi-level shift, cursor readout, and zoom/pan. Sidebar "Electronic Structure" section wires the controls and shows a live band-gap summary.

### Tests
- Added 38 tests: 14 `BandAnalysisTests`, 11 `DOSAnalysisTests`, 8 `BandGrapherTests`, 5 `DOSGrapherTests`. Full suite now at 1086 tests.

### Fixed
- Band/DOS grapher plot geometry: the plot top-edge used `bounds.height - topMargin`, which always produced a negative plot height and rendered the graphs empty; corrected to `topMargin` so the graphs actually draw.

## [1.1.26] — 2026-07-30

### Fixed
- Coordination neighbor readout now sorts by distance (nearest first) instead of element symbol, so the 16-neighbor cap keeps the closest neighbors.

### Tests
- Removed 6 diagnostic-only tests (print-only, no assertions) from `DiagnosticTests.swift`. Added a regression test for distance-first neighbor sorting. Full suite now at 1048 tests.

### Documentation
- Reconciled `CLAUDE.md` with the current codebase (1048 tests, four SPM targets, 38 modules, 16 parser families, render invariants, and state/UI traps).

## [1.1.25] — 2026-07-30

### Added
- K-path-editor cumulative reciprocal distance display, candidate hover tooltips, viewport node labels, and automatic BZ framing. Physical incoming/cumulative distances (Å⁻¹) with break-aware component handling. MetalView NSTrackingArea hover with candidate tooltips. Label overlay styles (atom/routeNode/selectedRouteNode/tooltip) with export filtering. AppKit reciprocal accessibility elements and keyboard navigation. BZPresentation.framedCamera with one-shot entry framing and camera restoration. Scale-safe Double lattice/BZ math with adaptive G-star completeness proof and bounded construction budgets. Centering detection with one-to-one multiplicity matching.

### Changed
- ReciprocalCell hardened with scale-safe Double arithmetic, adaptive G-star completeness proof, bounded construction budgets, and centering detection with one-to-one multiplicity matching.

### Tests
- Added 125 tests: 11 new test files for reciprocal-space UX — CenteringDetectionTests, BZFramingTests, BZConstructionBudgetTests, BZScaleInvarianceTests, BZSkewCompletenessTests, ReciprocalCellTests, ReciprocalDistanceTests, ReciprocalUXIntegrationTests, MetalViewHoverTests, LabelOverlayViewTests, and ReciprocalAccessibilityTests — plus enhancements to existing test suites (AppExportTests, AppSafetyTests, KPathEditorTests, KPathNodeSelectionTests, RendererTests). Full suite now at 1053 tests.

## [1.1.24] — 2026-07-29

### Added
- Opt-in, lazy, cancellable accelerated periodic image-aware coordination analysis for molecules and skew 1D/2D/3D cells, with configurable covalent-radius scale, same-atom and multiple-periodic-image neighbors, deterministic shells/CN, bounded CSR storage/work, selected-neighbor readout, an atom-table CN column and `cn:` filtering, and optional 3D/2D/polyhedral coloring.

### Changed
- Added async debounce/stale-generation safety, effective expanded-cell handling for displayed supercells, and preservation of active coordination coloring in PNG and raster-backed vector exports.

### Tests
- Added 70 tests: 33 CoordinationAnalysisTests, 19 CoordinationIntegrationTests, 9 additional AtomTableViewTests, 5 additional RendererTests, and 4 additional AppExportTests. Full suite now at 928 tests.

## [1.1.23] — 2026-07-29

### Added
- Exact skew-cell-safe minimum-image displacement and distance for periodicDim 0…3; periodic-aware distance measurement uses the minimum image for both the readout and rendered line; a virtualized read-only atom table with Cartesian/fractional coordinates, element/label filtering, and linked multiple selection that can drive active distance measurement.

### Changed
- Reconciled the roadmap, release history, state-file extension, export descriptions, and symmetry/k-path documentation with the implemented application.

### Fixed
- Resolved a main-actor async test deadlock.
- Made the periodic distance readout and rendered measurement line use the same minimum-image displacement, and connected atom-table selection to active distance measurement.

### Tests
- Added 90 tests: 28 PeriodicGeometryTests, 6 PeriodicMeasurementTests, 32 AtomTableViewTests, 19 AtomTableIntegrationTests, and 5 RendererTests regressions. Suite now at 858 tests.

## [1.1.22] — 2026-07-29

### Added
- Added CIF declared symmetry-operation parsing, asymmetric-unit expansion with periodic deduplication, and completeness promotion enabling spglib analysis and canonical k-paths on expanded structures.

### Fixed
- Hardened CIF tokenization, numeric parsing, cell assembly, and group dispatch against malformed and non-finite input, with strict per-record validation and parse-local reentrant state.

### Tests
- Added focused tests for CIF symmetry expansion, periodic deduplication, completeness promotion, and strict token/numeric/cell safety. Suite now at 762 tests.

## [1.1.21] — 2026-07-28

### Added
- Added File > Revert To Saved, File > Open Recent submenu (standard NSDocumentController recents with Clear), reopen-last-file on launch (UserDefaults-backed with empty-viewer fallback), and drag-and-drop file loading onto the viewer.
- Added a standard Edit menu (Undo/Redo/Cut/Copy/Paste/Select All routed to first responder) with Copy Current View to clipboard.
- Added collapsible, remembered sidebar sections across all 12 major sections (persisted independently in UserDefaults).
- Added automatic source-file watching, multiple independent structure windows, and a dynamic Window menu.
- Added configurable export dimensions, background color, and transparency with format-aware validation.
- Added a searchable command palette with keyboard navigation and responder-chain routing for text-editing commands.

### Changed
- Drag-and-drop parsing now runs off the main thread with generation-ordered install and directory rejection.
- Edit menu follows standard macOS ordering (File, Edit, View).

### Tests
- Added focused tests for workflow integration, multi-window state, file watching, export options, and command-palette routing. Suite now at 658 tests.

## [1.1.20] — 2026-07-27

### Added
- Added VASP line-mode KPOINTS export with correct reciprocal-fractional header (pointsPerSegment, Line-mode, Reciprocal), endpoint-pair encoding with shared-node duplication and blank-line separators between segments, singleton rejection, and a dedicated "VASP" sidebar button.

### Changed
- Renamed per-segment sampling stepper from "QE samples" to the format-neutral "Samples per segment" since it now controls both QE and VASP interpolation counts.
- Removed 26 stale diagnostic, trivial, and well-established tests; suite now at 585 tests.
- Solidified the Longcat-subagent implement-review-fix workflow in documentation.

## [1.1.19] — 2026-07-27

### Added
- Added user-configurable per-segment k-path sampling density (2…200) with a sidebar stepper, persistence in `.mvis-state`, and load-time clamping.

## [1.1.18] — 2026-07-27

### Added
- Added a collapsible Structure Summary panel to the sidebar showing lattice lengths, angles, volume, Hill-sorted formula, density, atom counts, and symmetry data for both molecular and crystal scenes.
- Added IUPAC conventional atomic masses for density calculation.

## [1.1.17] — 2026-07-27

### Added
- Added GUI File > Save State As and File > Export actions with constrained output types, source-alias protection, sheet-based error reporting, and atomic writes.
- Added visible-layer-aware canvas export that includes element labels and BZ landmark overlays.
- Added `showColorPlane` persistence in `.mvis-state` files with backward-compatible defaults and animation-frame-preserving lifecycle propagation.

## [1.1.16] — 2026-07-26

### Added
- Added an interactive Brillouin-zone k-path editor: click deterministic Γ/vertex/edge/face landmarks to append nodes, orbit while editing, rename/reorder/delete points, undo or clear edits, restore the generated default, and export QE or XCrySDen KPF paths.
- Rendered selectable BZ landmarks as white crosses only while editing, and the active route as depth-tested amber segments with cyan nodes; editing keeps the Metal canvas available even when graph or color-plane data is loaded.
- Persisted edited routes in `.mvis-state` files and preserved them across animation-frame rebuilds and unrelated view changes.
- Added a conventional File menu containing Open (`⌘O`), with Quit in the macOS application menu.

### Fixed
- Kept editor, renderer, and export coordinates in the conventional reciprocal basis, including correct primitive-to-conventional conversion for fcc/bcc defaults and a distinct canonical bcc `N` point.
- Rejected malformed, non-finite, oversized, or overlong persisted k-path data transactionally, capped routes at 1,024 nodes, and safely skipped malformed render points.
- Made measurements reject invalid indices, non-finite coordinates, and degenerate angle/dihedral geometry instead of indexing or normalizing unsafe data.
- Made band plotting and distance generation degrade safely for malformed channel layouts, jagged energy rows, non-finite values, and invalid drawing bounds.

### Tests
- Expanded the macOS suite to 433 tests, including 69 focused k-path geometry, picking, editing, persistence, cache, animation, and Metal-render regressions.

## [1.1.15] — 2026-07-23

### Fixed
- Rejected non-finite and out-of-range coordinates in XSF, CIF, and XYZ input, and hardened the C-to-Swift atom bridge against C-structure layout changes.
- Rejected non-finite Quantum Espresso band energies, k-points, weights, reciprocal vectors, and Fermi energies before mesh inference; overflow-prone lattice indexing now fails safely.
- Bounded Brillouin-zone construction for pathological atom counts and highly anisotropic or non-finite cells, preventing unrepresentable conversions and excessive geometry work.
- Bounded k-path interpolation and XCrySDen KPF multiplier arithmetic, with safe handling for non-finite coordinates, extreme sampling counts, and integer overflow.
- Hardened isosurface generation and caching against malformed dimensions, short or non-finite geometry, non-finite field values, and stale same-sized fields without rescanning unchanged shared value storage per frame.
- Kept animation reload and saved-frame restoration consistent by synchronizing field metadata, clamping isovalues to each destination field, and clearing only stale atom selections and measurements.
- Prevented finite-but-unrepresentable scroll deltas from corrupting camera distance, preserved the selected projection on Reset View, and made invalid color-plane data display a truthful diagnostic.
- Validated raster-backed vector export dimensions and source-image size before writing, and made EPS creation work for both new destinations and atomic overwrites without leaving partial output.

### Tests
- Expanded the macOS test suite to 362 tests, including pathological band, Brillouin-zone, k-path, isosurface, animation, input, cache, and vector-export regressions.

## [1.1.14] — 2026-07-16

### Fixed
- Hardened XSF/AXSF, Quantum Espresso, CIF, FHI-aims, PDB, WIEN2k, and CRYSCAL parsing against malformed, truncated, non-finite, and ambiguous input while preserving useful `ParseError` diagnostics.
- Corrected Quantum Espresso `ibrav` lattice orientations, case-insensitive `celldm` handling, direct DATAGRID forms, CIF loop boundaries, and symbol-based XSF atom rows.
- Added overflow-safe limits for bond generation, supercell expansion, cell rendering, isosurface generation, and offscreen export allocation.
- Made renderer and export failures graceful, including unsupported graph formats, invalid dimensions, Metal allocation failures, and EPS overwrite failures.
- Preserved scene/state behavior across supercell, slab, camera, pan, magnification, frame reload, and renderer-unavailable paths.

### Tests
- Expanded the macOS test suite to 312 tests, including parser, renderer, export, state, and adversarial regression coverage.

## [1.1.2] — 2026-07-11

### Fixed
- **Brillouin-zone overlay now renders for all lattice types**, including highly anisotropic slab cells (e.g. GaAsH), which previously returned a nil polyhedron and showed nothing. Root cause was the isotropic `shellCutoff` radius filter discarding the dense reciprocal directions of elongated cells, combined with a greedy primitive-basis reduction that over-reduced multi-atom conventional cells. Replaced with crystallographic centering detection (P/I/F) from the atomic basis offsets and a canonical primitive reduction; the G-star is now enumerated completely per-direction.
- **`Cell.reciprocalVectors` corrected for non-orthogonal cells**: reciprocal vectors are columns of `v.inverse` (not `v.inverse.transpose`), verified `a*·b = 0`, `a*·a = 2π` exactly for skew cells. Cubic results unchanged.
- **BZ overlay is cached** (`Renderer.build` keyed on cell + base atoms) so it builds once and redraws cheaply — fixing the seconds-long mouse-drag lag that occurred with the overlay on for crystals with a large G-star. Supercell expansion does not invalidate the cache.
- **Slabs saved in a `.mvis-state` file are now actually applied** to the atoms (previously a bare field assignment; headless export ignored them).
- **Saved animation frame (`currentFrame`) is honored again**: re-opening a state or headless export re-parses and renders the saved frame instead of the CLI default.

### Added 2026-07-10 (present in this release)
- Quantum Espresso PWscf **output** (`.pwo` / `.out`) parser, Brillouin-zone + k-path tooling, orthographic projection by default, hide-structure toggle.

## [1.1.1] — 2026-07-10

### Added
- Quantum Espresso PWscf **output** (`.pwo` / `.out`) parser: reads the final cell (`CELL_PARAMETERS` in alat/angstrom/bohr), atomic positions (`ATOMIC_POSITIONS` with per-step unit dispatch), and `bravais-lattice index`; multi-step relaxations/MD become AXSF-style animation frames. Registered the `--pwo` flag and `.pwo` / `.out` extensions.
- Brillouin-zone + k-path tooling: reciprocal lattice (`Cell.reciprocalVectors`, 2π convention), BZ polyhedron (Wigner-Seitz via the existing `Geometry.polyhedronFaces` run in reciprocal space, with centering recovered from the atomic basis offsets), special-point extraction (Γ/edge/line/face), k-path interpolation, and export to QE `K_POINTS crystal` and XCrySDen `.kpf` (with ISS rational multiplier). A "Brillouin Zone" sidebar toggle overlays the BZ wireframe; a crystal-only "K-Path" section lists the auto high-symmetry path (fcc/bcc/sc) and exports it.
- **Orthographic projection by default** (`Camera.perspective` now defaults to `false`); the existing "Orthographic" toggle flips it. Removed by the "Orthographic" toggle.
- **Hide structure** toggle: hides atoms/bonds/polyhedra while keeping the cell frame, axes, and BZ overlay so the user can focus on the Brillouin zone. Persists through the state file.
- Polyhedral display mode exposed in the sidebar picker (was filtered out); `.contcar` / `.vasp` added to the open panel; 2D-mode element labels now use the renderer's effective 2D camera.

### Fixed
- Vertex-stride mismatch in `makeFlat2DVertexDescriptor` / `makePolyVertexDescriptor` (declared SIMD-aligned strides of 32/48 that didn't match the 28/36-byte packed Swift vertex structs) that blew each 2D atom quad into huge corrupted triangles.
- Analysis/measurement mode state drift: the Analysis menu and sidebar now route through the single `state` source of truth via `beginMeasurementMode(_:)`; "Selection" (`.none`) now correctly resets the mode.
- `VectorExporter` → `RasterExporter` rename: the PDF/SVG/EPS/PS export is raster-wrapped-in-vector, not true primitive output.
- C element table completed to H–Og (Z=1–118): previously dropped Sc, Y, the lanthanides, and Hf–Ir, leaving them at Z=0 (no color/radius/bonds).
- POSCAR negative scaling now treated as the VASP cube-root-of-volume convention instead of a naïve negative multiplier.
- `syncFromState()` re-entrancy: added an `isSyncingState` guard after it was found to recurse infinitely (it mirrors scene-derived values back into `@Published` state, whose `didSet` re-fires `onChange`).
- Brillouin-zone toggle direction (now correctly `state → scene`, the renderer's source of truth) and `syncFromScene` initialization of `isCrystal` / `showBrillouinZone` / `kPathPoints`.
- BZ face drawing now emits explicit consecutive edge-pairs so Metal's `.line` primitive traces complete polygon loops instead of every-other edge.
- State file format migrated to the documented flat top-level contract (source, displayMode, supercell, slab, background, show flags, atomScale, bondRadius, currentFrame, lighting, optional camera) instead of nesting a whole `Scene` blob.

### Assets
- Added QE-output fixtures (`si_scf.out`, `si_relax.out`) to `MolVisAppTests/Fixtures/`.

## [1.1.0] — 2026-07-08

### Added
- Quantum Espresso PWscf input parser: reads `.pwi` / `.in` / `.inp` files, including the `&SYSTEM` namelist (`ibrav`, `celldm`, `nat`, `ntyp`), `ATOMIC_SPECIES`, `ATOMIC_POSITIONS` (alat / bohr / angstrom / crystal), and `CELL_PARAMETERS`. Supports all 17 Bravais-lattice cases (`latgen`) and digit-suffixed species labels (`Fe1` → Fe).
- Force-parser CLI flags: `--xsf`, `--xyz`, `--pdb`, `--axsf`, `--pwi` override the extension-based dispatch, so a `.xsf` file renamed to `.xyz` hits the right parser.
- `Reset View` button (top of sidebar): reframes the camera — center on centroid, distance from bounding sphere, rotation cleared.
- Atom selection: click (no-drag) atoms to toggle selection; turns selected atoms bright yellow.
- Measurements: in Distance / Angle / Dihedral modes, picking the right number of atoms computes the quantity automatically. A cyan line connects the picked atoms; a docked bottom readout panel shows each selected atom's index, element symbol, Cartesian coordinates, and (when a unit cell is present) crystal fractional coordinates, plus the measured value.
- World-space lighting so shading stays fixed to the structure as you orbit.
- New structure examples under `Assets/`: BiFeO3, Si (diamond, zincblende), ZnS, GaAsH, fcc slabs, and QE inputs.

### Fixed
- Supercell now draws one unit-cell box per replica, centred on the whole atom set (atoms no longer strayed outside the boxes).
- Slab filtering: changing the slab distance no longer compounds on a previous filter; the atom set is always rebuilt from the full widened cell.
- Bond detection now uses XCrySDen's covalent-radii table verbatim (removes the old 1.3 fudge factor).
- Camera orbit now rotates around the camera's current up/right axes instead of world-fixed axes — horizontal drag orbits horizontally regardless of tilt.
- Vertical drag direction matches expectation (drag up tilts the view as expected).
- Headless `--export` no longer hangs: the export path now terminates the process via `NSApp.terminate(nil)` after a successful render.
- Headless input-file resolution now skips force-format flags, so `mcrysden --pwi file.in` works.
- Forced parse on non-matching content fails gracefully with a clear error.
- Atom-selection readout: fixed a crash (`String(format:)` with `%@` + Swift String on arm4) that aborted the process when the readout panel first rendered. The readout window is now bottom-docked with a macOS-style rounded panel and standard traffic-light buttons, and closing the main window terminates the program.

### Assets
- Added crystal/molecule example files to `Assets/` (BiFeO3, Si, ZnS, GaAsH, fcc-410, QE inputs).

## [1.0.0] — (initial release)

Native macOS crystal/molecule viewer — a from-scratch Swift/Metal reimagining of XCrySDen 1.6.2. Reads XSF, AXSF, XYZ, and PDB structures and renders crystals and molecules interactively via Metal, plus a headless PNG export mode.
