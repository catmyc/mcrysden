# mcrysden roadmap

Last updated: **2026-08-08 (v1.2.1: review-fix hardening — color-plane cache pointer safety, slab/supercell reframe ordering, Finder/CLI dedup and flag validation, Wannier90 import bounds; 36 focused tests)**.

Status legend: `[x]` done · `[~]` partly done · `[ ]` todo. "file" = an example input is on hand for immediate test.

## Implemented foundation (through v1.1.32)

### File formats
- [x] XSF (structure + `DATAGRID_3D`/`2D`, including `.xsf.gz`), AXSF animation
- [x] XYZ, PDB, CIF, POSCAR / CONTCAR / VASP
- [x] Quantum Espresso PWscf input `.pwi/.in/.inp` (all 17 `ibrav`)
- [x] Quantum Espresso PWscf output `.pwo/.out` (final cell + positions; multi-step relax/MD → AXSF frames)
- [x] Gaussian Cube/G98 multi-orbital grids and BXSF band grids/Fermi surfaces, including `.bxsf.gz`
- [x] WIEN2k `.struct`, CRYSCAL `.r1`, ORCA output, and FHI-aims `geometry.in`/`coord.out`
- [x] Quantum Espresso band structures and total/projected DOS tables, including standard projected-DOS filenames
- [x] Force-format CLI flags for all 16 parser families: `--xsf --axsf --xyz --pdb --pwi --pwo --cif --poscar --cube --bxsf --struct --crystal --orca --fhi --bands --dos`

### Display & appearance
- [x] All 7 display modes: ball-stick, space-fill (CPK), wireframe, polyhedral (Voronoi-like half-space intersection via `Geometry.polyhedronFaces`), 2D line / 2D point / 2D ball-stick
- [x] Blinn-Phong lighting + material sliders (ambient/diffuse/specular/shininess/light azimuth/elevation); camera-relative controls converted to a world-space light each frame, including matching rotation-sensitive orientation-gizmo shading (v1.1.46)
- [x] Solid + vertical-gradient background (`gradient_top`); CPK element table H–Og (Z=1–118)
- [x] Atom scale + bond radius sliders, element labels (`⌘L`), cell frame, axes, orientation gizmo
- [x] Polyhedral mode exposed in the sidebar picker

### Structure & camera tools
- [x] Atom selection (click-to-toggle, yellow highlight) + covalent-radii bonds
- [x] Measurement: distance / angle / dihedral, with the bottom-docked readout panel (index, element, Cartesian + crystal coords, value)
- [x] Supercell expansion, slab with h/k/l plane controls, Reset View
- [x] Camera orbit + option-drag pan + scroll zoom; orthographic projection toggle (default ON)
- [x] Brillouin-zone overlay (Wigner-Seitz cell of reciprocal space, cached per cell+atoms) + high-symmetry k-path with export to QE `K_POINTS crystal` and XCrySDen `.kpf`
- [x] AXSF + multi-step animation playback UI; `--frame N` flag; saved `currentFrame` restored on reload

### State & export
- [x] `StateStore` save/load (`.mvis-state` flat JSON: appearance, visible layers, supercell/slab/frame, volumetric controls, k-path route/sampling, lighting, and optional camera). CLI load + headless `--export` honor saved supercell/slab/frame
- [x] Export: raster PNG plus raster-backed PDF/SVG/EPS/PS containers

### Tests
- [x] 33 focused tests (cap raised to 64): consolidated parser-family and scene workflows, renderer/raster/vector export, orientation-gizmo lighting, snapshot (FNV-1a pixel hash vs. committed goldens), state and camera-bookmark persistence, HPKOT's 29-variant oracle, periodic measurements and coordination distributions, atom-coordinate editing, animation-frame lifecycle, all-system CRYSCAL expansion, rendering quality, QE `tpiba_b` export, polyhedron volume/distortion oracles, two-structure RMSD matching, atom-table region/expression filters, and bond-distance labels. `MCRYSDEN_REGENERATE=1` regenerates goldens.

## v1.2.1 review-fix hardening
- [x] Color-plane texture cache no longer keys on a transient array base address; content changes (including in-place mutations) always rebuild, stable content always hits.
- [x] Slice textures rebuild on lattice changes; supercell/slab camera reframe runs once, post-slab, for both supercell- and slab-only geometry changes.
- [x] Finder/CLI double-open prevention via resolved file identity; `--fps`/`--anim-size`/`--format` flag-validation symmetry with `--frames`; `--frames 0` accepted as documented default.
- [x] Wannier90 6/7-token import bounds-guarded; coordination duplicate removal always active; HPKOT reciprocal-cell singularity threshold scale-relative; `FieldSlice.clipTriangles` doc/API contract corrected.
- [x] Suite at 36 focused tests: color-plane rebuild, Wannier90 count-guard, and coordination-dedupe regressions; exporter assertions hardened for CI.

## v1.1.14 hardening
- [x] Parser safety: malformed and truncated XSF/AXSF, Quantum Espresso, CIF, FHI-aims, PDB, WIEN2k, and CRYSCAL input fails with useful errors instead of traps or ambiguous fallback.
- [x] Resource safety: bond generation, supercell expansion, cell drawing, isosurface generation, and offscreen export enforce overflow-safe practical limits.
- [x] Export safety: invalid dimensions, unsupported graph formats, Metal allocation failures, and EPS replacement failures are reported without partial or misleading output.
- [x] UI/state safety: camera, pan, magnification, slab, frame reload, and renderer initialization failure paths are covered by regressions.

## v1.1.15 hardening
- [x] Band parsing rejects non-finite energies and reciprocal-space metadata before mesh inference, with overflow-safe integer-lattice reconstruction.
- [x] Brillouin-zone and k-path geometry enforce practical atom, anisotropy, plane-count, interpolation, and integer-arithmetic limits.
- [x] Isosurface generation rejects malformed or non-finite fields, while renderer caches reuse unchanged shared field storage and rebuild for changed same-sized data.
- [x] Animation frame changes keep sidebar field metadata synchronized, clamp isovalues to destination ranges, and invalidate stale selections and measurements.
- [x] Raster-backed PDF/SVG/EPS/PS wrapping validates dimensions against the source image; EPS supports safe creation and replacement without partial files.
- [x] Camera projection reset, extreme scroll input, and invalid color-plane diagnostics have dedicated regression coverage.

## v1.1.39 parser hardening
- [x] CRYSCAL: unrecognized space-group symbols fail with a useful error instead of silently defaulting to a cubic cell (wrong lattice constants and coordinates).
- [x] FHI-aims `coord.out`: full 118-element species-name table plus 118-element symbol fallback; "Silver"/"Platinum"-class names no longer resolve to colliding prefixes.
- [x] All Swift text loaders share the 200 MB input cap (matching the gzip path); ORCA blocks yielding no atoms fail instead of loading an empty molecule.
- [x] DOS parsing drops duplicate energy rows (first kept) instead of rejecting the file; decreasing energies still fail.
- [x] Three focused `ParserRobustnessTests` regressions replace lower-value volumetric cases, keeping the suite at exactly 32 tests.

## v1.1.16 interactive k-path editor
- [x] Interactive BZ landmark picking with deterministic Γ, vertex, edge-midpoint, and face-center candidates; click-to-append takes precedence over atom selection while edit mode is active.
- [x] Ordered sidebar route editing with bounded labels and routes, move/delete, undo, clear, generated defaults, and QE/KPF export controls.
- [x] Shared conventional reciprocal-basis mapping for picking, rendering, state persistence, and export, including corrected fcc/bcc default conversion and bcc `N` coordinates.
- [x] Editor-only white landmarks and persistent amber-route/cyan-node overlays share the cached BZ geometry and remain available when band, DOS, or color-plane views would normally replace the Metal canvas.
- [x] Edited routes persist through `.mvis-state`, animation reloads, and unrelated sidebar changes; malformed saved route data fails transactionally.
- [x] 69 focused editor tests; 433 tests in the v1.1.16 release suite.

## Implemented after v1.1.16: crystallographic symmetry, structure summary, k-path editing, sampling, and VASP export

The maintained coordinate, lifecycle, persistence, and export contract is documented in [`SYMMETRY_AND_KPATH.md`](SYMMETRY_AND_KPATH.md).

- [x] Detect the crystal system, space group, Hall setting, point group, Wyckoff positions, symmetry operations, and symmetry-equivalent atoms through vendored spglib 2.7.0; select the extended Bravais variant through the HPKOT/SeekPath implementation.
- [x] Produce standardized primitive and conventional cells with copied species/index mappings while retaining a separate input-oriented basis for display and export.
- [x] Generate HPKOT/SeekPath 2.1-compatible labels and paths for all 29 extended three-dimensional Bravais-lattice variants, including triclinic, monoclinic, orthorhombic, tetragonal, trigonal/rhombohedral, hexagonal, and cubic cases.
- [x] Map canonical paths into the input reciprocal basis and carry disconnected boundaries through editing, interpolation, rendering, persistence, and QE/VASP export; disable KPF export when a route contains an unrepresentable break.
- [x] Preserve generated-vs-user-edited route provenance across state reloads and geometry changes, remapping edited routes through Cartesian reciprocal space when the input cell changes.
- [x] Keep analysis deterministic at one explicit tolerance, bounded to 4,096 base atoms, and unavailable for malformed, non-3D, or known-incomplete asymmetric-unit inputs.
- [x] Verify all 29 variants against exact SeekPath-derived oracle fixtures; 545 tests in the then-current suite.

## v1.1.17–v1.1.19 (2026-07-27 session)

- [x] GUI Save State As and Export menu actions with constrained output types, source-alias protection, sheet-based error reporting, atomic writes, and visible-layer-aware canvas export including element labels and BZ landmarks.
- [x] Direct fractional-coordinate k-path editing with Apply/focus-loss commits, round-trip-safe coordinate drafts, provenance-aware undo, atomic route publication, and Sidebar-to-BZ selected-node highlighting.
- [x] Structure summary panel with lattice lengths/angles, volume, Hill-sorted formula, density, atom counts, and symmetry data; uses base atoms/cell for periodic crystals and marks incomplete asymmetric-unit inputs.
- [x] User-configurable per-segment k-path sampling with a 2…200 sidebar stepper, persistence in `.mvis-state`, and load-time clamping.

## Proposed function backlog

### Workflow and application integration
- [x] GUI Save State As and File-menu Export (v1.1.17).
- [x] Revert To Saved, Open Recent, reopen-last-file on launch, and drag-and-drop file loading (v1.1.21).
- [x] Copy-current-view to clipboard and standard Edit menu (v1.1.21).
- [x] Collapsible remembered sidebar sections (v1.1.21).
- [x] File watching and multiple structure windows (v1.1.21).
- [x] Configurable image dimensions/background/transparency (v1.1.21) plus persisted live and per-export Off/2x/4x/8x Metal multisample anti-aliasing with CLI override and device-capability fallback (v1.1.34).
- [x] Command palette (v1.1.21).

### Reciprocal space and k-paths
- [x] Per-component sampling budgets and disconnected path components.
- [x] Direct fractional-coordinate editing with undo/provenance preservation and selected-node highlighting between sidebar and BZ.
- [x] User-configurable per-segment k-path sampling for QE and VASP export.
- [x] Export VASP `KPOINTS` (line-mode, endpoint-pair encoding, blank-line segment separation).
- [x] K-path-editor cumulative reciprocal distance display, candidate hover tooltips, viewport node labels, and automatic BZ framing (v1.1.25). Band plots already use cumulative reciprocal distance.
- [x] Import k-paths from QE `K_POINTS crystal`, VASP line-mode `KPOINTS`, Wannier90 `kpoint_path`, and XCrySDen `.kpf` (v1.1.29): format sniffing, endpoint coalescing with break reconstruction, VASP-only sampling-density propagation (QE/Wannier90/KPF preserve the existing state/user preference), 1,024-node/16 MB bounds, provenance-safe user-edited routes, GUI Import panel, and CLI `--kpath`. Review hardening in v1.1.30: strict official Wannier90 begin/end parsing with inline comments, VASP label preservation, and BOM normalization.
- [x] Export Wannier90 `kpoint_path` and QE `K_POINTS crystal_b`/`tpiba_b` card-body forms. Both QE band cards use official weight-0 break jumps and w=n−1 subdivisions; `tpiba_b` converts through the active cell using the documented `alat = |cell.a|` convention.
- [x] Powder X-ray diffraction (v1.1.41): sidebar section + pop-out grapher with wavelength presets (Cu/Mo/Cr/Fe/Co/Mn/Ag Kα), max-2θ/FWHM controls, Miller-index peak labels, CSV and PNG/true-vector-PDF export; Waasmaier–Kirfel form factors (Z=1–118), structure factors, multiplicity via spglib-op orbit counting with the Friedel-pair factor (Laue-class fallback), Lorentz–polarization correction, d-degeneracy merging, Gaussian broadening; optional electron-density projection through a separable 3D DFT of the loaded scalar field (axis-aligned grids capped at 128³, fail-closed otherwise).

### Crystal input completeness
- [x] CIF declared-operation expansion and CRYSCAL completion (v1.1.35): numeric and unambiguous symbolic `CRYSTAL` groups 1–230 expand through convention-compatible spglib Hall settings with periodic species deduplication; `SLAB` builds bounded primitive hkl surface cells with requested layer/vacuum controls; and `POLYMER` is represented as a finite 1D-periodic crystal. Ambiguous/unknown symbols remain incomplete by design.

### Structure information and analysis
- [x] Structure summary with lattice lengths/angles, volume, density, composition, formula, and symmetry data (v1.1.18).
- [x] Atom table with fractional/Cartesian coordinates and coordination numbers (v1.1.35): element/label/CN filtering, linked multiple selection, transactional Cartesian/fractional coordinate editing, validation, bounded undo/redo, rebonding, and symmetry/k-path/coordination invalidation.
- [x] Coordination analysis (v1.1.35): periodic-image shells/CN and coloring, selected-neighbor readout, a bounded virtualized neighbor table, bond-length/angle histograms and CSV, normalized 3D RDF with explicit lower-dimensional unavailable states, and minimum-image distance/angle/dihedral measurements for skew 1D/2D/3D cells.
- [x] Polyhedron volume/distortion metrics (v1.1.36; hardened v1.1.37): first-shell convex-hull volume, mean bond-length distortion, ideal-angle-referenced angle deviation with trans/skew class exclusion, and volume ratio vs. the regular polyhedron; bounded virtualized metrics table and cancellable background sidebar analysis.
- [x] Two-structure comparison (v1.1.36; hardened v1.1.37): asynchronous reference loading, bounded per-element nearest-neighbor minimum-image matching for translated/skew cells, RMS/mean/max displacement, matched/unmatched reporting, 2D/3D displacement arrows, detail panel, escaped CSV, and current-view export propagation.
- [x] Atom filtering/highlighting by element, coordination, region, or selection expression, plus on-screen bond-distance labels (v1.1.36; hardened v1.1.37): fail-closed region/expression filtering (`x>0.5`, `a<=0.25`, `box:…`, `sphere:…`) joins the linked atom-table element/label/CN filters, and a persisted, bounded bond-distance label toggle draws clamped Å text at projected bond midpoints.

### Structure editing and generation
- [x] Atom editing and generation (v1.1.43): insert/remove/substitute atom operations, bulk displacement (all atoms or selection), and lattice-parameter editing (a/b/c, α/β/γ) join the existing Cartesian/fractional coordinate editing behind one unified NSUndoManager editing history with per-operation action names. The Structure Tools sidebar hosts an Element field + fractional/Cartesian position sliders for interstitial insertion, "Remove Selected (Vacancy)" and "Substitute Selected" defect actions, and Δx/Δy/Δz displace controls; all operations are gated on pristine geometry within the 10 000-atom cap, validated transactionally through the shared `StructureEditing` engine, rebond, re-run symmetry analysis, and regenerate generated k-paths (user-edited routes are remapped through Cartesian reciprocal space on lattice edits).
- [x] Primitive/conventional transformations, elastic cell deformation, cluster cutting, Miller-index surface-cell generation with termination selection and multi-slab stacking, and vacuum control (v1.1.42): a Structure Tools sidebar section converts the crystal to the spglib-standardized primitive/conventional cell (user k-paths remapped through Cartesian reciprocal space), applies a validated 3×3 elastic deformation matrix, cuts finite clusters into molecules, and builds 2D surface cells from any 3D crystal through the engine shared with CRYSCAL `SLAB` parsing (h/k/l steppers, atomic-layer count, termination block selection, contiguous slab stacking, and vacuum that both parametrizes the build and live-adjusts the current slab). The pre-existing h/k/l slab controls remain a fractional-plane display filter.
- [x] Defect workflows (v1.1.43): vacancies (remove selected atoms), substitutions (replace the species of a selection), and interstitials (insert an atom at a fractional/Cartesian position), with structure export to XSF, CIF, POSCAR, XYZ, and QE PWscf input via `File > Export Structure…` or the sidebar export buttons — each format matches its parser exactly so files round-trip.

### Electronic-structure analysis
- [x] Interactive band/DOS cursor readout, energy windows, Fermi adjustment, and zoom/pan for both graphers; linked plots (v1.1.44) show BOTH graphs side-by-side when a scene carries band + DOS data, with a dashed cross-graph cursor guide line at the hovered energy, a combined report, and linked print/export (one image with both panels, true-vector PDF).
- [x] Band VBM/CBM, direct/indirect gap, metallicity, and effective masses plus DOS center, width, gap estimate, spin moment, and electron-count consistency are surfaced with explicit unavailable/insufficient-data states and text/CSV export. Band extrema and estimated DOS gap edges are linked to graph markers. The combined band+DOS report (v1.1.44) adds "Gap agreement" and "Band-edge agreement" cross-check rows.
- [x] Projected species/orbital coloring (v1.1.44): QE projwfc filenames (`pdos_atm#N(Species)_wfc#M(orbital)`, `pdos_tot` + spin suffixes) enrich DOS series labels with species+orbital character, and the DOS grapher colors projected series by orbital (s/p/d/f fixed palette) with the legend showing the projection labels. Band-side projected coloring stays unavailable because QE `.out` band tables carry no projection weights.

### Volumetric data and rendering
- [x] Multiple independent isovalues (v1.1.38): additive spec list with per-level color/sign/enabled controls, capped at 8, persisted with backward-compatible legacy `isoLevel` fallback; classic ± pair remains the default.
- [x] Display-only clipping planes (v1.1.38): fractional h/k/l + distance convention culls structure atoms/bonds/polyhedra and Sutherland–Hodgman-clips isosurface/Fermi meshes without scene mutation.
- [x] Region integration (v1.1.38): bounded uniform-lattice trilinear sampling over box/sphere regions with live integral/mean/volume readouts and whole-field integration.
- [x] Configurable colormaps (viridis/turbo/inferno/grayscale) and contour-level counts for the color plane, persisted and backward compatible.
- [x] Volume slices (v1.1.38): arbitrary fractional-plane samples of the 3D field rendered as depth-tested colormap textures (masked samples transparent), up to 3 per scene.
- [x] Color-plane compositing (v1.1.38): the 2D grid renders as a textured quad inside the Metal scene with structure/isosurfaces, with optional 3D marching-squares contour lines; the fullscreen canvas swap is removed.
- [x] Standard crystallographic `[100]`/`[110]`/`[111]` camera views.
- [x] Three document-scoped named camera bookmark slots with save, recall, and clear actions; exact validated presentation/projection restoration; disabled recalls for empty slots; and optional `.mvis-state` persistence.
- [x] Adaptive scale indicators (v1.1.33): persisted opt-in Show Scale with an adaptive 1-2-5 Å/nm bar, orthographic-span and perspective camera-center-plane conventions, orbit/zoom/viewport-stable placement, shared live/raster/raster-backed-vector label compositing, and suppression for graph/color-plane views or invalid geometry.
- [x] Rendering quality (v1.1.35): persisted configurable line widths, scene-object transparency, depth cueing, bounded ambient-occlusion and soft-shadow approximations with quality levels, publication presets and `--preset`, plus the v1.1.34 live/export MSAA controls and safe device fallback. Defaults preserve prior rendering.
- [x] Higher-resolution labels and true vector export for cells, BZs, k-paths, and graphs (v1.1.40: PDF/SVG exports carry real vector primitives for the cell frame, BZ wireframe, k-path route, axes, displacement arrows, and labels; band/DOS/color-plane graphs export as true-vector PDF; EPS/PS remain raster-backed); image backgrounds (v1.1.40: fullscreen image backdrop with sidebar picker, scale-to-cover, silent fallback, persistence); printing (v1.1.40: File → Print… for the Metal scene and graphs); and stereo/anaglyph rendering (v1.1.40: red-cyan / green-magenta dual-eye merge, MSAA-resolved, persisted, off by default).

### Animation, conversion, and extensibility
- [x] Animation playback and timeline (v1.1.45): playback speed slider (0.1–20×) and loop toggle drive the existing frame timer; timeline thumbnails (≤24, evenly sampled, click-to-seek) render every frame offscreen; per-frame energy/force/volume/RMSD metrics are computed for multi-frame files with a summary line, CSV export, and a pop-out plot view with a metric picker; linear interpolation between frames (`FrameMetrics.interpolate`) and centroid trajectory alignment (`FrameMetrics.alignCentroid`) compose with the displacement-trail overlay (per-atom line strips in the Metal renderer).
- [x] Animation export (v1.1.45): `AnimationExporter` renders each frame offscreen and writes animated GIF (ImageIO), APNG (hand-written PNG chunks: IHDR/acTL/fcTL/IDAT/fdAT/IEND with zlib + CRC32), and MP4 (AVFoundation H.264 from pixel buffers); wired to the sidebar "Export Animation…" button and the headless `--export-anim` CLI flag (`.gif`/`.apng`/`.mp4`, optional `--fps` and `--anim-size WxH`).
- [x] Batch conversion and external-code converters (v1.1.45): `Converter` loads any supported input and writes XSF/CIF/POSCAR/XYZ/QE-PWscf through the round-trip-tested `StructureWriter` (atomic temp+replace); headless `--convert <out>` (format by output extension), `--convert-all <dir> --format <fmt>` (batch, skips unparseable and target-incompatible files, `maxFiles` cap), and the XCrySDen-style verbs `--pwi2xsf`, `--pwo2xsf`, `--struct2xsf`.
- [x] Embedded scripting, plugins, and project files (v1.1.45): `ScriptRunner` executes line-based scripts (quoted args, `#` comments, `help`/`quit`, line-numbered errors) headlessly via `--script` with `echo`/`load`/`convert`/`export-anim`/`project-save`/`project-load`/`plugins` commands; `PluginRegistry` registers named analysis plugins with two built-ins (band-gap, dos-gap); `ProjectStore` saves/loads `.mvis-project` JSON envelopes combining the structure, bands, DOS, and volumetric datasets, with a sidebar "Save Project…" action.

## Tier A — implementation status

All 10 original Tier A items complete: Gaussian Cube/G98, BXSF/Fermi surfaces, 3D isosurfaces, 2D color planes/contours, QE bands, QE force/stress/energy data, WIEN2k, CRYSCAL, ORCA, and FHI-aims. `[x]`

## Tier B — done

| # | Feature | Scope |
|---|---------|---------|
| 11 | **Density of states (DOS)** plot (total + projected) | QE `dos.x`/`projwfc.x` tables via `.dos`, `.pdos`, standard `.pdos_*` names, or `--dos`; total/projected series render in `DOSGrapherView` and export to PNG or raster-backed PDF/SVG/EPS/PS. |

## Tier C — validated by interaction, not files

- [x] **Structure editing** (v1.1.43): Cartesian/fractional coordinate edits, cut cluster/molecule, elastic cell deformation, multi-slab generation, insert/remove/substitute/displace operations, lattice-parameter editing, defect workflows, and a unified editing history are all implemented.
- [x] **On-screen bond distance labels** — live distance text above each bond (v1.1.36).
- [x] **Image-background variant** — fullscreen image backdrop with sidebar picker/Choose/Clear, scale-to-cover, silent fallback, `.mvis-state` persistence (v1.1.40), completed in v1.1.47 with a 4096 px decode cap + fail-closed aspect-preserving downsampling, alpha compositing over the solid/gradient background, and a Clear button (35 focused tests).
- [x] **Print** of the view (`NSPrintOperation`) (v1.1.40).
- [x] **Stereo / anaglyph** rendering (v1.1.40).
- [ ] **Tcl scripting engine** — a Tcl interpreter is not bundled; embedded scripting is provided by the `--script` line interpreter and `PluginRegistry` (v1.1.45) instead.
- [x] **External-code converters** (`pwi2xsf`, `pwo2xsf`, `struct2xsf`, …) as CLI verbs (v1.1.45).

## Reference: what XCrySDen implements

Authoritative gap list is against XCrySDen 1.6.2. Reference algorithms live in its tarball: `C/MarchCubes.c`, `C/polygonise.c`, `C/isosurf.c`, `C/isoline.c` (isosurface engine), `C/datagrid.c` (3D/2D scalar fields), `C/colorplane.c` (2D contour), `C/fs.c` + `C/cryDispFuncMultiFS.c` (Fermi surface), `F/fsReadBXSF.f` (BXSF reader), `F/recvec.f`, `F/pwKPath.f`, `F/kPath.f`, `F/wigner.f` (BZ/k-path math), `C/xcBz.c` + `C/bz.h`.
