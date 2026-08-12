# Changelog

All notable changes to mcrysden will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.10] — 2026-08-12

### Added

- **Band-surface plots (`--band-surf`)** — 3D surface sheets of the bands near the Fermi level for QE calculations on uniform k-point meshes. The surface region defaults to the first non-collinear plane of the scene's high-symmetry route (canonical, or user-defined via `--kpath`); each band within ±3 eV of E_f is sampled on a gridded parallelogram and rendered with a viridis colormap, lighting shading, painter's-algorithm depth sorting, a translucent Fermi plane, energy axis, corner labels, drag-to-rotate, printing, and PNG/PDF/SVG/EPS/PS export. Requires a `.pwo`/`.out`/`.bands` input with `bands (ev):` mesh data.
- **K-mesh band interpolation (`--bands`)** — a band structure computed on a k-grid is no longer rendered as disconnected dots: `--bands` interpolates every band along the default high-symmetry route (or the route imported with `--kpath`) via periodic trilinear interpolation of the axis-aligned Monkhorst-Pack mesh, producing a connected path with labeled high-symmetry points, working band-gap analysis, and the existing band plot/export pipeline.
- **Opt-in mesh DOS (`--dos`)** — the total DOS is no longer reconstructed automatically when a k-mesh band structure is opened. `--dos` triggers the reconstruction explicitly (combined with `--bands` for the linked band+DOS view); `--dos-table` force-parses dos.x/projwfc.x table files, taking over `--dos`'s previous force-format role. Plain DOS table inputs satisfy `--dos` as-is.
- **Band-surface persistence** — the computed `BandSurface` and its display toggle serialize into scene/project documents and state files.

### Changed

- `--dos` is now a plot-selection flag rather than a force-format flag; table files are opened by extension as before.
- The electronic-structure sidebar section is available whenever band, DOS, or band-surface data is present; graph views refresh on animation-frame reloads.


## [1.2.9] — 2026-08-11

### Added

- **QE mesh-derived total DOS** — uniform QE k-point meshes now produce a broadened total DOS directly from band eigenvalues and QE integration weights; separate `dos.x` output is not required. DOS units are dimensional: `states/eV` for molecules, `states/(eV·Å)` for 1D systems, `states/(eV·Å²)` for 2D crystals, and `states/(eV·Å³)` for 3D crystals.
- **DOS normalization metadata** — generated and table DOS curves retain provenance, periodic dimensionality, and unit-cell length/area/volume, with unit labels shown in the DOS graph and dimensional electron-count integration.

### Fixed

- **Metallic DOS gap reporting** — a zero-DOS region away from the Fermi level is no longer reported as the material gap when the DOS is metallic.

## [1.2.8] — 2026-08-10

### Fixed

- **Image-aware bond detection** — direct home-cell bonds are preferred over near-tied periodic images (including the GaAsH Ga–As pair); finite supercell rebonding uses its scaled lattice and skips bonds to undisplayed images.

## [1.2.7] — 2026-08-10

### Fixed

- **Periodic bond rendering** — bond cylinders, 2D bond lines, bond-distance labels, and polyhedron neighbor geometry now use the minimum-image displacement (via `PeriodicGeometry.minimumImageDisplacement`) instead of the direct coordinate difference. Periodic bonds are no longer drawn as long lines across the cell for genuine short bonds; e.g., the GaAs(001)-H slab's Ga–As bonds that cross the cell boundary are now drawn at their true ~2.4 Å length instead of the unwrapped 5.6–6.0 Å separation.
- **Supercell/slab replica self-bonds** — `Scene.rebond` now drops pairs whose minimum-image distance is below a 0.05 Å coincidence threshold. Expanded display views (supercell, slab, cluster) contain lattice-equivalent replicas of the same physical atom; with the primitive lattice the periodic search was bonding those replicas at ~0 distance. These were harmless zero-length render artifacts but polluted coordination counts and the bond list with phantom self-bonds (including phantom H–H bonds in the GaAsH supercell).

## [1.2.6] — 2026-08-09

### Fixed

- **texQuad vertex stride** — the textured-quad pipeline (volume slices + 3D color-plane compositing) declared a 24-byte vertex stride while its Swift vertex struct has a 32-byte stride (SIMD4 alignment tail padding), so vertices 1–5 read interleaved garbage. The descriptor now uses a shared `TexQuadVertex` type so descriptor stride and buffer layout always match. Same bug class as the v1.1.1 vertex-stride fix.
- **Atomic animation export** — MP4 and GIF now write to a temporary file and atomically move to the destination only on successful encode; a failed mid-stream encode no longer deletes the original file or leaves a truncated output. (APNG/PNG were already atomic.)
- **Project save alias guard** — Save Project now refuses to overwrite the loaded source file, matching the GUI structure/animation export guards.
- **Script runner + Converter alias guards** — the `--script` `convert` and `export-anim` commands now run the same inode-based `sameFile` check as the CLI argument path; `Converter.convert`'s internal alias check resolves symlinks/hardlinks via inodes instead of a path-string comparison.
- **Uniform 200 MB input cap** — all parsers, including the C-backed XSF/XYZ/PDB/AXSF/PWI/CIF/POSCAR paths that previously had no cap, now reject oversized files at the load entry.
- **ORCA fail-closed atom cap** — the ORCA loader now throws on >500K atoms instead of silently truncating, matching FHI-aims/CRYSCAL.
- **FHI-aims geometry.in incremental cap** — the 500K-atom check now fires per-atom during collection rather than only after.
- **CIF token leak** — the unterminated-CIF-token error path now frees accumulated loop-data row tokens, matching the EOF partial-row path.
- **Heavy-element covalent radii** — the bond-radii table now covers Z=101..118 (Md–Og) instead of stopping at Z=100, so superheavy elements form bonds.
- **UTF-8 BOM in C parsers** — a leading UTF-8 BOM is now skipped in all C-backed parsers so BOM-prefixed XYZ/XSF/etc. files parse instead of failing with a misleading atom-count error.
- **Grapher force-unwraps** — `BandGrapherView` and `DOSGrapherView` no longer trap on a malformed band/DOS file that reports bands but yields an empty energies array.
- **QE DOS row cap** — `DOSParser` now caps at 100K rows / 1M values (matching `CrystalDOSParser`) instead of allocating unboundedly on a giant `.dos` file.
- **Force parser finite check** — non-finite (NaN/inf) force components are now rejected per-atom triple rather than poisoning renderer force-arrow vertices.

### Added

- **CIF parsing test** — `CIFParserTests` (NaCl fixture) restores parse-side coverage removed during test consolidation.
- **Multi-light render test** — `MultiLightTests` exercises the multi-light rig through the offscreen render path (skipped when no Metal device).

## [1.2.5] — 2026-08-09

### Fixed

- **Lower-dimensional periodic bonding** — the C covalent-radii heuristic now uses a bounded exact minimum-image search over the active rank-1/2/3 periodic lattice, including skewed cells and bonds requiring translations beyond one cell.
- **Parser edge validation** — XSF grids, conversion-coordinate records, AXSF frame counts, POSCAR coordinate modes, and QE/CIF/POSCAR periodic cells reject malformed, singular, or pathological input before allocation or conversion.
- **Animation resource bounds** — animated export validates per-axis dimensions and total pixels in addition to its fps/frame caps; CLI scripts use the same frame and size limits.
- **Background cancellation** — animation, coordination-distribution, and powder-XRD workers use lock-backed cancellation tokens in addition to main-thread generation checks, so superseded expensive calculations stop promptly and cannot publish stale results.

## [1.2.4] — 2026-08-09

### Fixed

- **Parser hardening** — all declared atom counts (XYZ, PDB, XSF PRIMCOORD/ATOMS/CONVCOORD, AXSF ANIMSTEPS, QE input/output nat, POSCAR, FHI-aims, ORCA, WIEN2k) are now strictly parsed and capped at 500,000 with fail-closed errors instead of unbounded allocations; Swift loaders reject non-finite (NaN/inf/out-of-float-range) lattice and atom coordinates before they can poison framing/cameras.
- **QE unit tokens are case-insensitive** — `(BOHR)`, `{Alat}`, `(CRYSTAL)` etc. resolve correctly in `.pwi`/`.pwo` instead of silently defaulting to Ångström; unknown unit tokens are now hard parse errors; derived cells/scales/coordinates are validated finite and Float-representable (pwi/pwo/POSCAR).
- **Periodic bonding** — the C covalent-radii heuristic now applies minimum-image wrapping for crystal scenes (per `periodicDim`, exact 3ᵈ-image enumeration up to 3000 atoms, fractional-rounding fast path beyond), so bonds across cell boundaries and 1D/2D periodicities are detected; the bond buffer ceiling is lowered to 2M with a per-atom degree cap (128) so pathological dense structures fail closed instead of allocating gigabytes; the covalent-radii cache is now thread-safe for concurrent parsing.
- **APNG export** — fcTL/fdAT sequence numbers follow the spec (0, 1, 2, … strictly increasing), per-frame delay is now 1/fps seconds (was 100/fps), frames stream one at a time instead of pre-rendering all CGImages, and fps is bounded to 1…600 with a 1000-frame cap (MP4 timescale and `UInt16` conversions can no longer trap).
- **Animation export** — `--export-anim` now applies a companion `.mvis-state` (appearance, supercell/slab, saved camera and frame), honors `--preset`/`--msaa`, validates the destination against input/state aliasing, and starts from the saved frame when `--frame` is absent.
- **Saved-frame appearance** — re-parsing a saved animation frame (CLI/GUI open and in-window scrubbing) now carries every appearance/display/quality setting via a shared `Scene.adoptAppearance(from:)`, instead of a stale per-field list that dropped clip planes, iso-surface lists, volume slices, AO/shadow/quality, MSAA, opacity, anaglyph, color-plane styling, H-bond/molecular-surface/scheme/override settings, and more.
- **Animation background work** — thumbnail/trail/export workers snapshot all inputs on the main thread before dispatch and re-check their generation token on the main thread before publishing, eliminating data races and stale-result publication.
- **H-bond analysis** — periodic acceptor/H images use the exact minimum-image displacement (`PeriodicGeometry`, per `periodicDim`) instead of independent fractional rounding (wrong for skew cells, silent zero-mapping for singular cells); detection is accelerated with a uniform spatial grid (fallback to brute force above 4M buckets).
- **Powder XRD** — engine fails closed above 2000 atoms; the GUI recomputes debounced on a background queue with a generation token and skips work while the panel is hidden.
- **CRYSTAL band/DOS parsing** — leading count pairs use checked integer conversion (no `Int(Float)` trap on huge values) and unit-scaled energies are rejected when they overflow to non-finite.
- **QE band parsing** — a numeric token that is NaN/inf now fails the whole parse instead of silently shortening the row and misaligning every later band.
- **Z-matrix import** — `0`/`-` placeholder references are only accepted in the first three rows before any real reference (malformed later placeholders are rejected), and Cartesian positions are validated finite after the Double→Float conversion.
- **Heavy elements** — cube/CRYSCAL/WIEN2k symbol resolution now uses the full 118-element table instead of the 36/42-entry subset.
- **Export destinations** — GUI structure export, GUI animation export, and headless animation export refuse to overwrite the loaded source/state file (same-file alias check).
- **State/project/BXSF reads** — file-size caps (50 MB state, 200 MB project/BXSF) before unbounded `Data`/`String` allocation; `.mvis-state` now round-trips H-bond, molecular-surface, color-scheme, element-override, repetition-mode, rod, unicolor-bond and tessellation settings.
- **Supercell of 1D/2D structures** — expanding a non-periodic axis is refused with a warning instead of creating physically invalid replicas; rebonding uses the scene's own `periodicDim`.
- **2D display culling** — asymmetric-unit and clip-plane culling now applies to 2D line/point/ball-stick atom and bond drawing, matching the 3D paths.
- **Basis tools** — primitive/conventional transforms and deformation preserve user-edited k-paths (remapped through the new reciprocal basis) instead of replacing them with the generated route.
- **convert-all** — inputs whose output names collide (same stem, e.g. `a.xyz` and `a.pdb` → `a.xsf`) are skipped with a warning instead of silently overwriting each other.
- **Renderer fingerprint** — the atom-color-scheme hash no longer traps when `hashValue` is negative.

## [1.2.3] — 2026-08-09

### Added

- **CRYSTAL band/DOS import** — readers for CRYSTAL properties files (`fort.9`/`band` units and `fort.8`/`doss` units), gated on their canonical headers, feeding the band-structure and DOS analysis graphs; `--crystal-band`/`--crystal-dos` force-format flags.
- **WIEN2k `.struct` export** — full-lattice WIEN2k struct writer (Bohr units, P LATTICE header, non-equivalent atoms); `--format struct` / `--convert out.struct` in the CLI, plus the File menu path.
- **CRYSTAL input export** — `Save CRYSTAL-95/98/03 input` (LATTICE + FRACCOORD text) and `New CRYSTAL input` (empty template, exportable without a loaded structure).
- **Gaussian Z-matrix import** — `.gzmat`/`zmat` files (including generic and Cartesian indicators) via a native small-parser; `--gzmat` force flag; malformed coordinate rows fail loudly instead of truncating.
- **XCrySDen view-script save/load** — File menu `Save XCrySDen Script…` writes a `.tcl` view file (rotation/zoom/background/bonds/cell); opening a `.tcl` applies it to the current view, skipping unknown commands with a report.

### Fixed

- CRYSTAL DOS gate now accepts canonical `DENSITY OF STATES` headers (incl. `…PER ATOM`/`…PERCELL`) while still rejecting `BAND STRUCTURE` content; integrated-DOS (`DOSS(INTEGRATED)`) columns are dropped; band files tolerate leading `E(F)=` lines.
- Filename sniffing for extension-less CRYSTAL files (`band`, `doss`, `fort.8/9`) runs only when the extension is unrecognized, so `band.xyz`/`doss.pdb` keep their real formats.
- `--convert`/`--convert-all` accept `struct` and `d12` output targets (were dead cases).

## [1.2.2] — 2026-08-08

### Added

- **H-bonds** — detection (N/O/F donors+H, optional periodic acceptor images) with configurable max H…A distance / min D-H-A angle, and dashed-line display bound to the matched image copy.
- **Molecular surface** — probe-inflated (Connolly-style) isosurface via bounded marching cubes with opacity/color/probe settings; UInt16-index-safe vertex cap.
- **Color schemes** — coordination-number, slab-fraction, and signed slab-distance proportional coloring alongside the elemental default; per-frame cached metrics.
- **Per-element customization** — per-Z color, covalent/van-der-Waals radii, and label/font overrides via a periodic-table element editor sheet.
- **Unit-of-repetition toggle** — display full unit-cell content vs. the translational asymmetric unit.
- **Crystal cells as rods** — lit rod-cell rendering with thickness factor.
- **Unicolor bonds** — all bonds in a single configurable color.
- **Tessellation factor** — sphere/cylinder quality scale (0 = legacy fixed counts, byte-identical output).
- **Multi-light rig** — up to 6 configurable lights (empty = legacy single light, byte-identical default output).
- Force-arrow overlay now exposes its existing readout in the force dashboard; Y-snap tinting unchanged.

### Fixed

- Spurious double `shadowStrength` decode in `Scene` (redundant, harmless).
- Polyhedral/transparent-poly caches now key on the active color scheme and element overrides (stale colors after switching scheme), and cached molecular-surface meshes are released when the surface is disabled.
- Orientation gizmo and axis frames use the active light rig (multi-light) rather than the legacy single light.
- Molecular surface is gated on `Scene.showStructure` and drawn transparent atoms in the correct blend order.

## [1.2.1] — 2026-08-08

### Fixed

- Color-plane texture cache no longer keys on a transient array base address (dangling pointer could serve a stale texture or rebuild every frame); cache hits require CoW-storage identity with an exact element-wise content fallback, and cache invalidation clears the retained flat copy.
- `colorPlaneInputsUnchanged` now detects in-place grid mutations (storage identity plus full content comparison) instead of trusting per-row CoW base pointers alone.
- Slice textures rebuild when the cell changes (lattice-only edits no longer keep the old slice).
- Supercell/slab camera reframing happens once, after the slab is applied, for both supercell and slab-only geometry changes; a zero-radius (empty) pre-change scene is handled without division by zero.
- `application(_:openFiles:)` dedupes CLI-owned paths by resolved file identity (standardized path + symlink/hardlink inode) instead of raw string equality, so `./data.xyz` relaunched as an odoc event no longer opens the document twice; internally delivered duplicates open once.
- CLI validation is now symmetric: `--fps` and `--anim-size` require `--export-anim`, and `--format` requires `--convert`/`--convert-all`, matching the existing `--frames` contract; `--frames 0` is accepted and treated as "every remaining frame" per its documentation.
- Wannier90 k-path import no longer indexes out of bounds on 6/7-token rows: 8-token branches are guarded by exact token counts, the dedicated 6-token branch handles only its format, and malformed lines fail with the existing useful error.
- Coordination-analysis duplicate removal always runs (a sparse-system guard previously skipped it, letting same-atom periodic images be double-counted).
- HPKOT `reciprocalCellRowsDirect` uses the scale-relative singularity threshold like its siblings, so tiny reciprocal cells are no longer falsely rejected.
- Legacy `FieldSlice.clipTriangles` doc corrected (the renderer migrated to `clipTrianglesWithOverflow`; the wrapper is retained for tests).
- `StateStore` comment corrected for the exact accepted `Int` range.

### Changed

- Suite at 36 focused tests: added a color-plane rebuild regression, Wannier90-import count-guard regressions, and coordination dedupe coverage; existing MP4/GIF/APNG assertions hardened for CI.

## [1.2.0] — 2026-08-08

### Changed

- Image-background variant completed: decoded background images are capped at a 4096 px maximum dimension with aspect-preserving, fail-closed downsampling (no unbounded memory or Metal texture-limit risk), and the fullscreen backdrop quad now alpha-blends so transparent PNGs composite over the solid/gradient background instead of painting black. The sidebar Image background section gains a Clear button to remove the chosen image (falling back to the solid/gradient background), and two regressions cover the downsample cap and transparent compositing (35 focused tests).

## [1.1.46] - 2026-08-08

### Fixed

- Orientation-gizmo arrow normals now retain their world-space rotation before being transformed into camera space, so light and dark regions move across the gizmo during camera rotation in agreement with the structure.

### Changed

- The test suite now contains 33 focused tests, including a gizmo-lighting coordinate-space and rotation-sensitivity regression.

## [1.1.45] — 2026-08-06

### Added

- Animation playback and timeline: a playback-speed slider (0.1–20×) and Loop toggle drive the frame timer (interval `0.1/speed`, wrapping at the end when looping); a timeline thumbnail strip (≤24 frames, evenly sampled, click-to-seek) renders every frame offscreen via `TimelineThumbnails`; per-frame energy/force/volume/RMSD metrics (`FrameMetrics`) feed a sidebar summary, a CSV export, and a pop-out `FrameMetricsPlotView` with a metric picker; `FrameMetrics.interpolate` produces linearly interpolated intermediate frames and `FrameMetrics.alignCentroid` centroid-aligns trajectories to a reference frame, composing with the new per-atom displacement-trail line strip drawn by the renderer (Show Trails toggle).
- Animation export: `AnimationExporter` renders each frame offscreen (`PngExporter.render` — a new memory-only render path extracted from `export`) and writes animated GIF (ImageIO), APNG (hand-written PNG chunks IHDR/acTL/fcTL/IDAT/fdAT/IEND with zlib deflate and table CRC32), and MP4 (AVFoundation H.264 from pixel buffers). Wired to the sidebar "Export Animation…" button and the headless `--export-anim` CLI flag (`.gif`/`.apng`/`.mp4`, optional `--fps N` and `--anim-size WxH`).
- Batch conversion and external-code converters: `Converter` loads any supported structure input and writes XSF/CIF/POSCAR/XYZ/QE-PWscf through the round-trip-tested `StructureWriter` with atomic temp+replace writes. New headless flags: `--convert <out>` (output format inferred from the extension), `--convert-all <dir> --format <xsf|cif|poscar|xyz|qe>` (directory batch; skips unparseable and target-incompatible files, capped at 200 inputs), and the XCrySDen-style verbs `--pwi2xsf <out>`, `--pwo2xsf <out>`, `--struct2xsf <out>` (forced source format, XSF output required).
- Embedded scripting, plugins, and project files: `ScriptRunner` runs line-based scripts headlessly via `--script` (quoted args, `#` comments, `help`/`quit`, line-numbered errors) with `echo`/`load`/`convert`/`export-anim`/`project-save`/`project-load`/`plugins` commands; `PluginRegistry` registers named analysis plugins (deterministic order, first-name-wins) with built-in `band-gap` and `dos-gap` plugins; `ProjectStore` saves/loads `.mvis-project` JSON envelopes (versioned `ProjectBundle`) combining the structure, bands, DOS, and volumetric datasets, with a sidebar "Save Project…" action.

### Changed

- Test suite remains at exactly 32 focused tests; eight new regressions (animation playback speed/loop/stepping, frame metrics + interpolation + thumbnails + alignment + plot view, GIF/APNG/MP4 export + memory render, headless conversion + CLI verbs, batch conversion, project round-trip, script runner + plugin registry) replaced consolidated lower-value cases (two parser-robustness checks, four powder-XRD cases into two, four electronic-analysis cases into two, polyhedron+comparison, writer round-trip+validation, renderer geometry+headless export — all assertions preserved).

## [1.1.44] — 2026-08-06

### Added

- Linked band/DOS plots: a scene carrying both band-structure and DOS data now shows both graphs side by side (band left, DOS right, 1 px divider) instead of DOS taking precedence; hovering either graph draws a dashed cross-graph cursor guide line at the same energy on the other, and the sidebar cursor readout keeps working. Print and export render the linked view as one image with both panels (true-vector PDF via the shared graph export path).
- Combined band+DOS analysis report: `ElectronicAnalysisPresentation.linkedReport(band:dos:)` appends "Gap agreement (bands vs DOS)" and "Band-edge agreement (bands vs DOS)" cross-check rows (Δ ≤ 0.5 eV → agree, else disagree; explicit unavailable/insufficient states) to the 7 band rows and 5 DOS rows; the sidebar uses it whenever both datasets are present, with the same text/CSV export buttons.
- Projected species/orbital coloring: `DOSParser.parse(_:sourceName:)` recognizes QE projwfc filenames (`pdos_atm#N(Species)_wfc#M(orbital)`, `pdos_tot[_up|_down]`) and enriches PDOS series labels with species+orbital character ("Fe p", "Si s up"); the DOS grapher colors projected series by orbital via a fixed s/p/d/f palette (blue/red/green/purple) with the legend showing the projection labels. `DOSOrbitalColoring` classifies labels word-wise (last single-letter s/p/d/f token, so single-letter species S/P/F never shadow the orbital) and is exported through the standard graph path.
- `LinkedGraphsView`: reusable side-by-side container rendering one or both graphers, with live AppKit child drawing and an explicit export/print path that paints children manually (including transparent exports) — used by the viewport, print, and `App.exportScene`.

### Changed

- Test suite remains at exactly 32 focused tests; four new electronic-analysis regressions (linked-report cross-checks, projwfc label enrichment, orbital coloring, linked-cursor/export rendering) replaced consolidated lower-value cases (two parser-robustness temp-file checks merged, structure-editing lattice test merged into the editing test, structure-tools deformation merged into transforms, surface-builder termination/stacking merged into slab construction — all assertions preserved).

## [1.1.43] — 2026-08-06

### Added

- Structure editing and generation backlog: insert/remove/substitute atom operations, bulk displacement, lattice-parameter editing, a unified full editing history, defect workflows (vacancies, substitutions, interstitials), and structure export to XSF/CIF/POSCAR/XYZ/QE PWscf input.
- Atom editing in the Structure Tools sidebar: an Element field plus fractional/Cartesian position sliders insert atoms (interstitial workflow); "Remove Selected (Vacancy)" and "Substitute Selected" act on the linked viewport/atom-table selection; displace controls move all atoms or the selection by a Δx/Δy/Δz vector. All operations are gated on pristine geometry (no supercell/slab) within the 10 000-atom edit cap, validated transactionally through a shared `StructureEditing` engine (finite positions, element range 1…118, displacement ≤ 1000 Å, non-empty selection), rebond, mirror the base/preslab snapshots, re-run symmetry analysis, regenerate generated k-paths, and surface rejection reasons as status text.
- Lattice-parameter editing: a/b/c and α/β/γ text fields prefilled from the current cell rebuild the cell in the standard convention (a along x, b in the xy-plane) with all atoms repositioned to their preserved fractional coordinates; Apply is transactional, Reset refills the fields, and user-edited k-paths are remapped through Cartesian reciprocal space when the cell changes.
- Unified full editing history: the scene-snapshot undo stack that previously covered only atom-coordinate edits now covers every editing operation (coordinate edit, insert, remove, substitute, displace, lattice) through one NSUndoManager with per-operation action names ("Insert Atom", "Remove Atoms", "Substitute Species", "Displace Atoms", "Edit Lattice Parameters", "Edit Atom Coordinate"), bounded to 64 levels and the 10 000-atom cap.
- Structure export: `File > Export Structure…` (format popup accessory) and five sidebar export buttons write the current structure as XSF (CRYSTAL/PRIMVEC/PRIMCOORD, or ATOMS for molecules), CIF (P1, fractional sites), POSCAR (VASP5 symbol+counts, Direct), XYZ, or QE PWscf input (ibrav=0, ATOMIC_SPECIES with masses, ATOMIC_POSITIONS crystal, CELL_PARAMETERS angstrom, K_POINTS gamma) — each matching its parser exactly so files round-trip; failures are reported with explicit errors and empty/singular geometry is rejected.

### Changed

- Test suite remains at exactly 32 focused tests; six new regressions (structure-edit engine insert/remove/substitute/displace + lattice editing, structure-writer round-trips and validation, controller editing/lattice/gating/export workflow) replaced lower-value anaglyph-mask, vector-export-contract, region-integration, controller deformation/cluster, and engine vacuum cases.

## [1.1.42] — 2026-08-06

### Added

- Structure Tools sidebar section (runtime-only, not persisted) covering the structure-editing backlog: primitive/conventional cell transformations, elastic cell deformation, cluster cutting, and Miller-index surface-cell generation with termination selection, multi-slab stacking, and vacuum control.
- Primitive/conventional transformations: a Representation picker converts the displayed crystal to the spglib-standardized primitive or conventional cell (Cartesian-equivalent positions, labels preserved through the input-to-primitive mapping), or back to the input cell via the source file; user-edited k-paths are remapped through Cartesian reciprocal space, generated paths regenerate.
- Elastic cell deformation: a 3×3 row-major deformation matrix applies v′ = M·v to the cell and all atom coordinates, with finite/±100-entry/singularity validation, reset-to-identity, and transactional application through the same install path as a file load.
- Cluster cutting: keeps atoms within a user-set radius of a chosen center and converts the result into a non-periodic molecule (cell dropped, bonds recomputed); empty clusters and invalid centers/radii fail with explicit status text.
- Miller-index surface-cell builder: exact integer-lattice construction (gcd reduction, extended-GCD step vector, Bezout in-plane kernel basis) shared with the CRYSCAL `SLAB` parser path, generating a 2D surface cell from any 3D crystal — h/k/l steppers, atomic-layer count, termination selection (which consecutive block of atomic planes to keep, with the available range reported), multi-slab stacking (contiguous repeats along the surface normal), and vacuum control that both parametrizes the build and live-adjusts the current slab's vacuum (c-length − slab extent), including a syncFromState mirror with derived-vacuum comparisons.
- Surface builder reports built-plane count and slab extent to bound the termination stepper and confirm the result in status text; the old fractional-plane Slab filter remains unchanged.

### Changed

- `CRYSCALSlabBuilder` extracted from `Parser.swift` into the shared `SurfaceCellBuilder` engine (same algorithm and caps; file-level SLAB validation and error messages preserved); the `crystal_Pt322.r1` SLAB fixture remains byte-equivalent.
- `loadFile` split into bookkeeping + `installScene(_:frameIndex:frameCount:)` so derived structures (transforms, clusters, slabs) install through the identical scene-install path without re-opening the source file; recent-document and file-watching semantics unchanged.
- Test suite remains at exactly 32 focused tests; seven new structure-tool regressions (surface-cell construction + CRYSCAL extraction, termination/stacking, primitive/conventional round-trip, deformation/cluster, vacuum control, controller basis/surface/vacuum, controller deformation/cluster) replaced lower-value print, anaglyph-orientation, state-round-trip, and renderer-cache cases.

## [1.1.41] — 2026-08-06

### Added

- Powder X-ray diffraction simulation for crystals: a sidebar Powder XRD section (crystal-only) computes 2θ peak positions from the reciprocal lattice, structure-factor intensities from Waasmaier–Kirfel atomic form factors (Z = 1…118; Z > 98 use the Cf shape renormalized to f(0) = Z), powder multiplicities from the spglib symmetry operations (orbit counting with the Friedel-pair factor; Laue-class fallback when symmetry is unavailable), Lorentz–polarization correction, and d-degeneracy merging with combined labels and intensities. Wavelength presets (Cu/Mo/Cr/Fe/Co/Mn/Ag Kα), max-2θ and FWHM controls, Miller-index peak labels, and Gaussian-broadened profile curve; a pop-out grapher window plus CSV (peaks and curve) export, and PNG/true-vector PDF export through the shared graph-export path.
- Electron-density projection: with a volumetric file loaded, a "Use electron density" toggle computes the pattern from a separable 3D DFT of the scalar field projected onto reciprocal-lattice vectors (grid must be axis-aligned with the cell, capped at 128³ samples), replacing the atomic form-factor route; misaligned or oversized grids fail closed with a specific reason.
- Engine is fully bounded and fail-closed (non-finite parameters, singular cells, invalid atomic numbers, and out-of-range wavelengths all yield explicit unavailable reasons rather than traps or partial results).

### Changed

- Test suite remains at exactly 32 focused tests; three new Powder XRD regressions (NaCl/Si/Mg peak positions, multiplicities, and systematic absences; wavelength and form-factor oracles; electron-density projection with a physical intensity pin) replaced consolidated volumetric cases.

## [1.1.40] — 2026-08-05

### Added

- True-vector export for PDF and SVG: the scene renders once to a raster structure layer, then real vector primitives are overlaid for the cell frame, Cartesian axes (orientation gizmo), Brillouin-zone wireframe, k-path route (honoring breaks), displacement arrows, and labels (CoreText/`<text>`), projected with the same validated camera. Band/DOS/color-plane graphs export as true-vector PDF pages (view drawn directly into a CGContext PDF); any failure falls back to the previous raster wrap. EPS/PS remain raster-backed; PNG output is byte-identical.
- Higher-resolution labels: exports re-project labels at the export size, and PDF/SVG labels are true vector text.
- Image backgrounds: a third `Image` background style with a sidebar Choose… button, fullscreen scale-to-cover rendering through the shared textured-quad pipeline, silent fallback to the solid/gradient background on any load failure, suppression under explicit export background/transparency overrides, and `.mvis-state` persistence (empty path → nil; missing files do not fail the load).
- Stereo/anaglyph rendering: Off / Red-Cyan / Green-Magenta modes render both eyes (lateral parallax at 3% of the scene radius) into per-eye textures — MSAA-resolved when multisampling — and merge through per-channel masks; applied uniformly in the live view and exports; off by default so existing rendering is byte-identical; persisted in state with malformed values failing transactionally.
- Printing: File → Print… (⌘P) prints the currently visible layer — the Metal scene rendered at print resolution (2 px/pt, capped at 16 M pixels) with projected labels, or the displayed band/DOS graph — through `NSPrintOperation`, with validation errors surfaced as a sheet.

### Changed

- Test suite consolidated to exactly 32 focused tests; new regressions cover vector-format primitives and determinism, print representations and contracts, background-image rendering and fallbacks, and anaglyph channel masks/orientation.

## [1.1.39] — 2026-08-05

### Fixed

- CRYSCAL files whose space group cannot be resolved (unknown or ambiguous symbol) now fail with a useful `ParseError` instead of silently defaulting to a cubic cell and misparsing the lattice constants and coordinates.
- FHI-aims `coord.out` species names resolve through the complete 118-element name table plus the full element-symbol fallback, fixing wrong assignments such as "Silver" → Si (14) and "Platinum" → P (15) for names absent from the old table.
- Swift text loaders (PWO, ORCA, bands, FHI-aims, cube, CRYSCAL, WIEN2k struct, DOS) now bound input size to 200 MB like the gzip path, instead of unbounded `String(contentsOf:)`.
- ORCA coordinate blocks that yield no atoms now fail instead of silently loading an empty molecule.
- DOS files with a duplicated energy row load with the duplicate dropped (first occurrence kept) instead of being rejected; genuinely decreasing energies still fail.

## [1.1.38] — 2026-08-04

### Added

- Multiple independent isosurface levels: an additive spec list (level, color, sign, enabled) with per-level color pickers, sliders, and toggles in the sidebar, seeded from the legacy iso level, capped at 8, and persisted in `.mvis-state` with backward-compatible legacy `isoLevel` fallback.
- Display-only clipping plane (fractional h/k/l + distance convention): culls structure atoms/bonds/polyhedra and clips isosurface and Fermi-surface meshes via Sutherland–Hodgman half-space clipping, without mutating the scene; sidebar controls and state persistence with clamped load.
- Region integration: bounded uniform-lattice sampling with trilinear interpolation over box or sphere regions, live sidebar readout (integral, mean, volume, extrema, sample count) and whole-field integration.
- Configurable colormaps (viridis/turbo/inferno/grayscale) and contour-level counts for the color plane, persisted and backward compatible.
- Volume slices: arbitrary fractional-plane sampling of the 3D scalar field rendered as depth-tested textured quads in the Metal scene (colormap-mapped, masked samples transparent), up to 3 slices with sidebar controls and persistence.
- Color-plane compositing: the 2D grid now renders as a textured quad inside the 3D Metal scene together with structure and isosurfaces, with optional 3D marching-squares contour lines; the previous fullscreen canvas swap is removed.
- Textured-quad Metal pipeline (linear/clamp sampling, alpha discard) shared by slices and the color plane, including the MSAA export path.

### Changed

- The isosurface renderer cache generalizes from two fixed ± shells to a dynamic per-spec shell cache; the classic paired blue/orange shells remain the default when no spec list is configured, with byte-identical output.
- Test suite consolidated to exactly 32 focused tests; volumetric coverage (colormaps, region integration, field slicing, clipping, multi-iso, compositing) consolidated into `VolumetricTests.swift`.

## [1.1.37] — 2026-08-03

### Fixed

- Hardened first-shell polyhedron metrics: fixed shell-tolerance chaining, coplanar-facet volume overcounting, hull-edge angle selection, oversized-shell reporting, finite-input handling, scale-aware tolerances, and cancellable background lifecycle.
- Made structure comparison responsive and bounded with arbitrary periodic-image ranges for skew/translated cells, singular-cell rejection, complete no-match semantics, streamed/capped candidate work, cancellation, asynchronous reference loading, and stale-result invalidation after geometry changes.
- Propagated comparison displacement arrows into PNG and raster-backed vector exports and enabled them in 2D display modes; hardened comparison CSV escaping and source/target indexing.
- Hardened coordinate/region filters against malformed structured terms, empty region fields, and overflow, and bounded/clamped bond-distance labels with explicit Å units and hidden-structure behavior.

### Tests

- Kept exactly 32 focused tests while adding consolidated regressions for polyhedron shells/hulls, comparator bounds and cancellation, filter overflow, CSV escaping, comparison lifecycle/export propagation, 2D arrows, and bond-label bounds.

## [1.1.36] — 2026-08-03

### Added

- Completed the structure-information and analysis backlog:
  - First-shell coordination-polyhedron volume and distortion metrics (convex-hull volume, mean bond-length distortion, ideal-angle-referenced angle deviation, and volume ratio vs. the regular polyhedron) with a bounded virtualized metrics table and sidebar readout, derived from the coordination analysis on a background queue.
  - Two-structure comparison against a reference file with per-element nearest-neighbor minimum-image matching, RMS/mean/max displacement, matched/unmatched atom reporting, on-canvas displacement arrows, a detail panel, and text/CSV export.
  - Region and expression atom-table filtering: Cartesian and fractional coordinate comparisons (`x>0.5`, `a<=0.25`, …), Cartesian `box:` and `sphere:` regions, combinable with element/label and `cn:` terms; malformed structured terms fail closed.
  - On-screen bond-distance labels: a persisted Show Bond Distances toggle draws formatted Å text at each projected bond midpoint through the shared live/export label compositing path.

### Tests

- Kept 32 focused tests while adding consolidated coverage for polyhedron volume/distortion oracles, two-structure RMSD/unmatched matching (periodic, edge-wrapped, and molecular), atom-table region/expression filters, and bond-distance label projection/state round trips.

## [1.1.35] — 2026-08-03

### Added

- Completed coordination analysis with a bounded virtualized neighbor table, bond-length and bond-angle histograms/CSV, normalized 3D radial distribution functions, and periodic minimum-image angle/dihedral measurements for skew lower- and full-dimensional cells.
- Completed CRYSCAL structure expansion across space groups 1–230 using convention-compatible spglib Hall settings, plus bounded primitive hkl `SLAB` generation with layer/vacuum controls and finite 1D-periodic `POLYMER` representation.
- Added transactional Cartesian/fractional editing in the atom table with finite/singular-cell validation, molecule/crystal rebonding, bounded document undo/redo, and symmetry, k-path, BZ, summary, coordination, and distribution invalidation.
- Added persisted rendering-quality controls for line width, scene opacity, depth cueing, bounded ambient occlusion and soft shadows, quality levels, publication presets, and the `--preset` CLI override across live and exported render paths.

### Fixed

- Preserved asymmetric-unit completeness across coordinate edits, bounded dense AO/shadow and RDF work, corrected transparent-object ordering and line alpha, and made thick lines pixel/aspect/depth correct.
- Hardened CRYSCAL surface integer arithmetic, candidate limits, periodic in-plane deduplication, malformed-record diagnostics, and lower-dimensional cell semantics.

### Tests

- Kept 32 focused tests while extending consolidated cases for all-system CRYSCAL expansion, multi-layer slabs, coordinate edit/undo lifecycle, periodic coordination distributions and RDF oracles, renderer layout/quality/transparency, and state round trips.

## [1.1.34] — 2026-08-02

### Added

- Configurable Metal multisample anti-aliasing with persisted live Off/2x/4x/8x controls, per-export Use Document/Off/2x/4x/8x overrides, and `--msaa 1|2|4|8`. Live, PNG, and raster-backed PDF/SVG/EPS/PS rendering share the same multisample-resolve path, with safe fallback to the highest supported device sample count.

## [1.1.33] — 2026-08-02

### Added

- Standard crystallographic camera views: sidebar `[100]`, `[110]`, and `[111]` actions use active direct-lattice directions `u*a+v*b+w*c`, with deterministic roll while preserving framing and projection; actions are unavailable with descriptive help for missing or invalid cells, 2D display, or reciprocal k-path editing.
- Camera bookmarks: three document-scoped named slots with save, recall, and clear actions; exact validated presentation/projection restoration; disabled recalls for empty slots; and backward-compatible optional `.mvis-state` persistence.
- Persisted opt-in **Show Scale** with an adaptive 1-2-5 Å/nm bar; uses the orthographic span and perspective camera-center-plane convention; stays stable under orbit and responsive to zoom/viewport; available in live rendering plus raster/raster-backed vector export through shared label compositing; hidden for graph/color-plane views and invalid geometry.

### Fixed

- XSF `PRIMVEC` parsing now accepts blank and comment-only lines between its three vector records, allowing the bundled `fcc-410-1x1.xsf` slab and similarly formatted XCrySDen files to load while retaining finite-vector validation.

### Tests

- Consolidated the tracked suite from 100 to 32 focused tests while retaining parser-family and scene workflows, Metal/raster/vector rendering, snapshots, state and camera-bookmark persistence, HPKOT's complete 29-variant oracle, periodic measurements, animation lifecycle behavior, CRYSCAL expansion, and QE `tpiba_b` export.

## [1.1.32] — 2026-08-02

### Added

- QE `K_POINTS tpiba_b` card-body export with the same sampling and weight-0 break semantics as `crystal_b`. Route points are converted through the active reciprocal cell into Cartesian `2π/alat` units using the explicit convention `alat = |cell.a|`; missing, singular, non-finite, and unrepresentable inputs fail descriptively. The sidebar exposes a dedicated save action and filename.
- CRYSCAL numeric and unambiguous symbolic cubic `CRYSTAL` asymmetric-unit expansion for space groups 195–230 now uses caller-owned operations copied synchronously from the spglib database; symbolic Hermann–Mauguin names resolve through a normalized HM lookup. Expansion wraps and periodic-deduplicates sites by species, enforces input/operation/atom bounds, and enables downstream symmetry and canonical k-path analysis. Unknown, ambiguous, or non-cubic symbolic inputs are never guessed and remain incomplete; non-cubic numeric groups, `SLAB`, and `POLYMER` inputs remain incomplete.

### Fixed

- CRYSCAL parsing now reports one-based lines consistently, rejects unknown record kinds, and handles the actual `POLYMER` layout, which has a period record but no space-group record.

### Tests

- Reduced the tracked suite from 1,286 to 100 focused tests, retaining scene and format loading, Metal rendering and export, snapshots, state persistence, HPKOT's 29-variant oracle, periodic measurements, animation-frame lifecycle behavior, CRYSCAL cubic expansion, and QE `tpiba_b` export.

### Documentation

- Updated test-suite guidance, roadmap status, and symmetry/k-path interoperability documentation for v1.1.32.

## [1.1.31] — 2026-08-01

### Added

- Wannier90 `kpoint_path` export: official `begin/end kpoint_path` block with one row per connected edge; labels sanitized to single whitespace-free tokens capped at 64 characters, with deterministic generated labels (`K1`, `K2`, … by stable route index) for blank labels so a shared endpoint carries the same generated label in adjacent rows; disconnected components yield non-sharing rows, preserving breaks without special encoding; rejects routes with fewer than two points, over 1,024 nodes, no connected edge, orphan singleton nodes, or non-finite coordinates.
- QE `K_POINTS crystal_b` card-body export: one row per route point with official weight-0 jumps for route breaks (QE treats zero weight as a jump that emits only the next row's point, so disconnected components are not silently connected) and `w = n−1` subdivisions per edge for the editor's endpoint-inclusive sample count `n` (2…200 sampling, apportioned by edge length per component), so QE's generated point count exactly matches the editor's interpolation; the final row's weight is 0 and ignored by QE; rejects fewer than two points, over 1,024 nodes, and non-finite coordinates.
- Sidebar k-path export actions for all five formats in two rows (QE (.pwscf), QE crystal_b, Wannier90 / kpf, VASP) with per-format default filenames (`kpath.qe`, `kpath.crystal_b`, `kpath.win`, `kpath.kpf`, `KPOINTS`) and save-panel wiring; buttons that cannot encode the current route are disabled with an explanatory tooltip.

### Tests

- Added 24 tests: 18 `KPathExportInteropTests` (Wannier90/QE crystal_b output syntax and round trips, generated-label stability, break encoding, rejection paths) and 6 `KPathExportIntegrationTests` (export availability/help policy, per-format default filenames, sampling stamping, sidebar construction). Full suite now contains 1286 tests (up from 1262).

### Documentation

- Updated `docs/ROADMAP.md` (v1.1.31, 1286 tests), `docs/SYMMETRY_AND_KPATH.md` (export contract), `CLAUDE.md`, and the version test.

## [1.1.30] — 2026-08-01

### Fixed

- Review hardening for k-path import: strict parsing of official Wannier90 `begin kpoint_path` / `end kpoint_path` blocks, with inline `!`/`#` comments allowed on the delimiters, unterminated blocks and malformed/ambiguous rows rejected, and legacy bare blocks requiring an exact header and stopping at following keywords or scalar assignments; VASP line-mode labels preserved from a bare fourth column or after the first `!`/`#` comment marker; VASP-only sampling propagation so QE/Wannier90/KPF imports preserve an existing state/user sampling preference; CLI/state precedence and undo mirroring coverage; and UTF-8 BOM normalization applied before format detection.

### Tests

- Added 15 review-hardening tests (strict Wannier90 malformed/unterminated/comment cases, VASP suffix labels, BOM normalization, sampling preservation, CLI precedence). Full suite now contains 1262 tests (up from 1247).

### Documentation

- Updated `docs/ROADMAP.md` (v1.1.30, 1262 tests), `docs/SYMMETRY_AND_KPATH.md` (import contract), `CLAUDE.md`, `AGENTS.md`, and the version test.

## [1.1.29] — 2026-08-01

### Added

- K-path import from QE `K_POINTS crystal` cards, VASP line-mode `KPOINTS` files, Wannier90 `kpoint_path` blocks, and XCrySDen `.kpf` files, with content-based format detection, endpoint coalescing and break reconstruction for VASP/Wannier90 segments, VASP points-per-segment propagation (clamped to 2…200), and provenance-safe imported routes (`userEdited`, never auto-regenerated).
- GUI k-path import via a sidebar "Import…" open panel and CLI `--kpath <file>` import, including undo support, import-error sheets, aliasing guards against the input/state files, and crystal-only validation.
- Hardened parsing: 16 MB file bound, 1,024-node route cap, non-finite coordinate/weight rejection, automatic/grid and Cartesian VASP rejection with "not a band path" diagnostics, UTF-8 BOM and CRLF handling, and descriptive `KPathImportError` failures instead of traps.

### Tests

- Added 74 tests: 53 `KPathImportTests` unit tests (format detection, QE/VASP/Wannier90/KPF parsers, error paths, limits, export→import round trips) and 21 `KPathImportIntegrationTests` (sidebar undo/provenance, controller import, CLI `--kpath` parsing, sampling propagation, QE/VASP export round trips). Full suite now contains 1247 tests.

### Documentation

- Updated `docs/ROADMAP.md` (import feature complete, v1.1.29, 1247 tests), `docs/SYMMETRY_AND_KPATH.md` (import contract), `CLAUDE.md`, and the version test.

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
