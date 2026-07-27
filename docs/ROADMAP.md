# mcrysden roadmap

Last updated: **2026-07-27 (v1.1.20 VASP KPOINTS export implemented)**.

Status legend: `[x]` done · `[~]` partly done · `[ ]` todo. "file" = an example input is on hand for immediate test.

## Implemented in v1.1.2

### File formats
- [x] XSF (structure + `DATAGRID_3D`/`2D`, including `.xsf.gz`), AXSF animation
- [x] XYZ, PDB, CIF, POSCAR / CONTCAR / VASP
- [x] Quantum Espresso PWscf input `.pwi/.in/.inp` (all 17 `ibrav`)
- [x] Quantum Espresso PWscf output `.pwo/.out` (final cell + positions; multi-step relax/MD → AXSF frames)
- [x] Force-format CLI flags: `--xsf --xyz --pdb --axsf --pwi --pwo --cif --poscar`

### Display & appearance
- [x] All 7 display modes: ball-stick, space-fill (CPK), wireframe, polyhedral (Voronoi-like half-space intersection via `Geometry.polyhedronFaces`), 2D line / 2D point / 2D ball-stick
- [x] Blinn-Phong lighting + material sliders (ambient/diffuse/specular/shininess/light azimuth/elevation); world-space light
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
- [x] `StateStore` save/load (`.molvis-state` JSON: display mode, supercell, slab, background, show flags, atom scale/bond radius, lighting, optional camera, currentFrame). CLI load + headless `--export` honor saved supercell/slab/frame
- [x] Export: raster PNG + vector PDF/SVG/EPS/PS

### Tests
- [x] 362 tests: unit, snapshot (FNV-1a pixel hash vs. committed goldens), diagnostic, model-layer cache, parser-hardening, renderer-safety, export, state, and pathological-input regression tests. `MCRYSDEN_REGENERATE=1` regenerates goldens.

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

## v1.1.16 interactive k-path editor
- [x] Interactive BZ landmark picking with deterministic Γ, vertex, edge-midpoint, and face-center candidates; click-to-append takes precedence over atom selection while edit mode is active.
- [x] Ordered sidebar route editing with bounded labels and routes, move/delete, undo, clear, generated defaults, and QE/KPF export controls.
- [x] Shared conventional reciprocal-basis mapping for picking, rendering, state persistence, and export, including corrected fcc/bcc default conversion and bcc `N` coordinates.
- [x] Editor-only white landmarks and persistent amber-route/cyan-node overlays share the cached BZ geometry and remain available when band, DOS, or color-plane views would normally replace the Metal canvas.
- [x] Edited routes persist through `.molvis-state`, animation reloads, and unrelated sidebar changes; malformed saved route data fails transactionally.
- [x] 69 focused editor tests; 433 tests in the full macOS suite.

## Implemented after v1.1.16: crystallographic symmetry, structure summary, k-path editing, sampling, and VASP export

The maintained coordinate, lifecycle, persistence, and export contract is documented in [`SYMMETRY_AND_KPATH.md`](SYMMETRY_AND_KPATH.md).

- [x] Detect the crystal system, extended Bravais lattice, space group, Hall setting, point group, Wyckoff positions, symmetry operations, and symmetry-equivalent atoms through vendored spglib 2.7.0.
- [x] Produce standardized primitive and conventional cells with copied species/index mappings while retaining a separate input-oriented basis for display and export.
- [x] Generate HPKOT/SeekPath 2.1-compatible labels and paths for all 29 extended three-dimensional Bravais-lattice variants, including triclinic, monoclinic, orthorhombic, tetragonal, trigonal/rhombohedral, hexagonal, and cubic cases.
- [x] Map canonical paths into the input reciprocal basis and carry disconnected boundaries through editing, interpolation, rendering, persistence, and QE export; disable KPF export when a route contains an unrepresentable break.
- [x] Preserve generated-vs-user-edited route provenance across state reloads and geometry changes, remapping edited routes through Cartesian reciprocal space when the input cell changes.
- [x] Keep analysis deterministic at one explicit tolerance, bounded to 4,096 base atoms, and unavailable for malformed, non-3D, or known-incomplete asymmetric-unit inputs.
- [x] Verify all 29 variants against exact SeekPath-derived oracle fixtures; 545 tests pass in the full macOS suite.

## v1.1.17–v1.1.19 (2026-07-27 session)

- [x] GUI Save State As and Export menu actions with constrained output types, source-alias protection, sheet-based error reporting, atomic writes, and visible-layer-aware canvas export including element labels and BZ landmarks.
- [x] Direct fractional-coordinate k-path editing with Apply/focus-loss commits, round-trip-safe coordinate drafts, provenance-aware undo, atomic route publication, and Sidebar-to-BZ selected-node highlighting.
- [x] Structure summary panel with lattice lengths/angles, volume, Hill-sorted formula, density, atom counts, and symmetry data; uses base atoms/cell for periodic crystals and marks incomplete asymmetric-unit inputs.
- [x] User-configurable per-segment k-path sampling with a 2…200 sidebar stepper, persistence in `.molvis-state`, and load-time clamping.

## Proposed function backlog

### Workflow and application integration
- [x] GUI Save State As and File-menu Export (v1.1.17).
- [ ] Revert, recent files, reopen last file, drag-and-drop, file watching, and multiple structure windows.
- [ ] Configurable image dimensions/background/transparency/anti-aliasing, and copy-current-view to clipboard.
- [ ] Standard Edit menu with undo/redo, collapsible remembered sidebar sections, and a command palette.

### Reciprocal space and k-paths
- [x] Per-component sampling budgets and disconnected path components.
- [x] Direct fractional-coordinate editing with undo/provenance preservation and selected-node highlighting between sidebar and BZ.
- [x] User-configurable per-segment k-path sampling for QE and VASP export.
- [x] Export VASP `KPOINTS` (line-mode, endpoint-pair encoding, blank-line segment separation).
- [ ] Cumulative reciprocal distance display, candidate hover tooltips, viewport node labels, and automatic BZ framing.
- [ ] Import k-paths from QE, VASP, Wannier90, and KPF.
- [ ] Export Wannier90 `kpoint_path` and additional QE band-path forms.
- [ ] Powder X-ray diffraction with wavelength selection, peak labels, Miller indices, and optional electron/reciprocal-lattice projections.

### Crystal input completeness
- [ ] Expand CIF and CRYSCAL asymmetric-unit inputs through declared symmetry operations, with periodic-site deduplication and preserved species/index mappings, so they can use symmetry analysis and generated canonical k-paths.

### Structure information and analysis
- [x] Structure summary with lattice lengths/angles, volume, density, composition, formula, and symmetry data (v1.1.18).
- [ ] Atom table with fractional/Cartesian coordinates, and coordination numbers.
- [ ] Coordination shells, coordination coloring, nearest-neighbor tables, bond/angle distributions, radial distribution functions, and minimum-image periodic measurements.
- [ ] Polyhedron volume/distortion metrics and two-structure comparison with displacement vectors and RMS displacement.
- [ ] Atom filtering/highlighting by element, coordination, region, or selection expression, plus on-screen bond-distance labels.

### Structure editing and generation
- [ ] Insert, remove, substitute, and displace atoms; edit Cartesian/fractional coordinates and lattice parameters; and maintain full undo/redo history.
- [ ] Primitive/conventional transformations, elastic cell deformation, cluster cutting, multi-slab construction, Miller-index surface generation, termination selection, and vacuum control.
- [ ] Defect workflows for vacancies, substitutions, and interstitials, with export to XSF, CIF, POSCAR, XYZ, and QE input.

### Electronic-structure analysis
- [ ] Interactive band/DOS zoom, pan, cursor readout, energy windows, Fermi adjustment, linked plots, and projected species/orbital coloring.
- [ ] Automatic VBM/CBM, direct/indirect band-gap, and effective-mass analysis.

### Volumetric data and rendering
- [ ] Arbitrary 3D-grid slices and clipping planes, multiple independently colored/transparent isovalues, paired orbital lobes, region integration, configurable colormaps, and contour levels.
- [ ] Composite structure/color-plane/isosurface views instead of mutually exclusive layers.
- [ ] Multisample anti-aliasing, configurable line widths, transparency, depth cueing, ambient occlusion/soft shadows, standard `[100]`/`[110]`/`[111]` views, camera bookmarks, scale indicators, and publication presets.
- [ ] Higher-resolution labels and true vector export for cells, BZs, k-paths, and graphs; image backgrounds, printing, and stereo/anaglyph rendering.

### Animation, conversion, and extensibility
- [ ] Timeline thumbnails, playback speed/looping, GIF/APNG/video export, trajectory alignment, displacement trails, interpolation, and per-frame energy/force/volume/distance plots.
- [ ] Batch conversion/rendering and external-code converters such as `pwi2xsf`, `pwo2xsf`, and `struct2xsf`.
- [ ] Embedded scripting, parser/analysis plugins, and project/session files combining structures, bands, DOS, and volumetric datasets.

## Tier A — implementation status

All 10 Tier A items complete. `[x]`

## Tier B — done

| # | Feature | Scope |
|---|---------|---------|
| 11 | **Density of states (DOS)** plot (total + projected) | QE `dos.x`/`projwfc.x` tables via `.dos`, `.pdos`, standard `.pdos_*` names, or `--dos`; total/projected series render in `DOSGrapherView` and export to PNG/PDF/SVG/EPS/PS. |

## Tier C — validated by interaction, not files

- [ ] **Structure editing**: cut cluster/molecule; substitute/remove/insert/displace atoms; elastic cell deformation; multi-slab; undo-redo stack.
- [ ] **On-screen bond distance labels** — live distance text above each bond.
- [ ] **Image-background variant** — only `solid` + `gradient_top` exist.
- [ ] **Print** of the view (`NSPrintOperation`).
- [ ] **Stereo / anaglyph** rendering.
- [ ] **Tcl scripting engine** — validating an interpreter needs a written test suite.
- [ ] **External-code converters** (`pwi2xsf`, `pwo2xsf`, `struct2xsf`, …).

## Reference: what XCrySDen implements

Authoritative gap list is against XCrySDen 1.6.2. Reference algorithms live in its tarball: `C/MarchCubes.c`, `C/polygonise.c`, `C/isosurf.c`, `C/isoline.c` (isosurface engine), `C/datagrid.c` (3D/2D scalar fields), `C/colorplane.c` (2D contour), `C/fs.c` + `C/cryDispFuncMultiFS.c` (Fermi surface), `F/fsReadBXSF.f` (BXSF reader), `F/recvec.f`, `F/pwKPath.f`, `F/kPath.f`, `F/wigner.f` (BZ/k-path math), `C/xcBz.c` + `C/bz.h`.
