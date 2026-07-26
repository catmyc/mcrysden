# Changelog

All notable changes to mcrysden will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.16] — 2026-07-26

### Added
- Added an interactive Brillouin-zone k-path editor: click deterministic Γ/vertex/edge/face landmarks to append nodes, orbit while editing, rename/reorder/delete points, undo or clear edits, restore the generated default, and export QE or XCrySDen KPF paths.
- Rendered selectable BZ landmarks as white crosses only while editing, and the active route as depth-tested amber segments with cyan nodes; editing keeps the Metal canvas available even when graph or color-plane data is loaded.
- Persisted edited routes in `.molvis-state` files and preserved them across animation-frame rebuilds and unrelated view changes.
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
- **Slabs saved in a `.molvis-state` file are now actually applied** to the atoms (previously a bare field assignment; headless export ignored them).
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
