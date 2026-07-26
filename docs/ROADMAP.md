# mcrysden roadmap

Last updated: **2026-07-26 (v1.1.16 shipped; symmetry and standard paths accepted next)**.

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

## Next priority: crystallographic symmetry and standard paths
- [ ] Detect crystal system, Bravais lattice, space group, point group, Wyckoff positions, and symmetry-equivalent atoms.
- [ ] Standardize primitive and conventional cells while preserving species and coordinate mappings.
- [ ] Generate conventional high-symmetry labels and recommended paths for every three-dimensional Bravais lattice, including triclinic, monoclinic, orthorhombic, tetragonal, trigonal/rhombohedral, hexagonal, and cubic variants.
- [ ] Keep symmetry/path generation deterministic, tolerance-aware, safe for malformed cells, and consistent with BZ rendering, picking, persistence, and QE/KPF export.

## Proposed function backlog

### Workflow and application integration
- [ ] GUI Save State, Save State As, Revert, recent files, reopen last file, drag-and-drop, file watching, and multiple structure windows.
- [ ] File-menu export, configurable image dimensions/background/transparency/anti-aliasing, and copy-current-view to clipboard.
- [ ] Standard Edit menu with undo/redo, collapsible remembered sidebar sections, and a command palette.

### Reciprocal space and k-paths
- [ ] Direct fractional-coordinate editing, per-segment sampling, disconnected path segments, cumulative reciprocal distance, and selected-node highlighting between sidebar and BZ.
- [ ] Candidate hover tooltips, viewport node labels, automatic BZ framing, and imports from QE, VASP, Wannier90, and KPF.
- [ ] Export VASP `KPOINTS`, Wannier90 `kpoint_path`, and additional QE band-path forms.
- [ ] Powder X-ray diffraction with wavelength selection, peak labels, Miller indices, and optional electron/reciprocal-lattice projections.

### Structure information and analysis
- [ ] Structure summary with lattice lengths/angles, volume, density, composition, formula, symmetry, atom table, fractional/Cartesian coordinates, and coordination numbers.
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

## Half-done (mechanism exists, UI missing)
- [~] **Save-state menu item** — `StateStore.save` writer is implemented and load is wired to the CLI and headless export, but there is **no menu item or button** to trigger a save from the GUI. A one-line UI hook onto the existing writer.
- [~] **`--pwo` / `--out` to AXSF conversion reuse** — `.pwo` already produces animation frames; could back a `pwo2xsf`-style command.

## Tier A — implementation status

### Done in v1.1.3

| # | Feature | Test fixtures verified on |
|---|---------|---------------------------|
| 1 | **Volumetric isosurface engine** (`DATAGRID_3D`/`2D` in XSF and `.xsf.gz`; marching cubes; iso-value slider; inverse-transpose world-space gradient normals; positive/negative shells) | `Assets/volumetric_grid.xsf` (rendered, frame-spanning), compressed-XSF dispatch regression, `Si datagrid` render test |
| 2 | **Gaussian `.cube` / `.g98` reader** (z-fastest cube layout; voxel-interleaved multi-orbital fields; GUI orbital selector + saved selection) | `N2O.cube` (19×19×31 grid, 3 atoms, Bohr→Å), exact synthetic multi-orbital ordering test |
| 3 | **Fermi-surface reader** (BXSF, multi-band shell at the Fermi level; `.gz` peeling) | `MgB2.bxsf` (3 bands, Fermi 0.523), `RhBulkFcc.bxsf` (negative vectors); PNG + PDF/SVG/EPS/PS export |
| 6 | **WIEN2k `.struct` reader** | 24 files (Bohr→Å, fractional atoms, multi-position sites + rotation matrices) |
| 7 | **CRYSTAL `.r1` reader** | 16 files (all crystal systems via space group → lattice params + angles; trigonal/hexagonal/monoclinic) |
| 8 | **Orca `.out` reader** | `pbe.accOpt.AsF2-C2C2.out` via header sniff (ORCA banner; checked AFTER PWSCF marker) |
| 9 | **FHI-aims / FHI98MD reader** | `GaAsSurface_coord.out` (lattice + species blocks; Bohr→Å) plus standard `geometry.in` (`lattice_vector`, `atom`, `atom_frac`) with automatic filename dispatch |
| 5 | **Band-structure extraction** (QE `bands (ev):` k-point + eigenvalue blocks → line graph) | `CH3Rh111.out` (56 k-points × 69 bands via `--bands`); 2D Grapher (Fermi line, k-path, energy axes) swaps in for the 3D canvas |
| 4 | **Color-plane / 2D-contour rendering** (DATAGRID_2D → viridis colormap + marching-squares contours; anisotropic dims; GUI toggle swaps canvas) | `mol-urea2D.xsf` (41×42 charge-density-difference plane); rendered to 56994 non-white px / 176 distinct hues |

### Done in v1.1.10

| # | Feature | Test fixtures verified on |
|---|---------|---------------------------|
| 10 | **Force / stress / energy readouts + force arrows** | `CH3Rh111.out`, `si_relax.out`; `ForceParser` (per-atom forces, Total force, stress tensor, energy auto-fill); `Renderer.drawForceArrows` (shaft + barb overlay); SideBar toggle/scale + readout (`showForces`, `forceScale`, `buildForceSummary`); `StateStore` persistence. |

### Remaining Tier A (still TODO)

None — all 10 Tier A items complete.

### Tier B — done

| # | Feature | Scope |
|---|---------|---------|
| 11 | **Density of states (DOS)** plot (total + projected) | QE `dos.x`/`projwfc.x` tables via `.dos`, `.pdos`, standard `.pdos_*` names, or `--dos`; total/projected series render in `DOSGrapherView` and export to PNG/PDF/SVG/EPS/PS. |

### Tier C — validated by interaction, not files

- [ ] **Structure editing**: cut cluster/molecule; substitute/remove/insert/displace atoms; elastic cell deformation; multi-slab; undo-redo stack.
- [ ] **On-screen bond distance labels** — live distance text above each bond.
- [ ] **Image-background variant** — only `solid` + `gradient_top` exist.
- [ ] **Print** of the view (`NSPrintOperation`).
- [ ] **Stereo / anaglyph** rendering.
- [ ] **Tcl scripting engine** — validating an interpreter needs a written test suite.
- [ ] **External-code converters** (`pwi2xsf`, `pwo2xsf`, `struct2xsf`, …).

## Reference: what XCrySDen implements

Authoritative gap list is against XCrySDen 1.6.2. Reference algorithms live in its tarball: `C/MarchCubes.c`, `C/polygonise.c`, `C/isosurf.c`, `C/isoline.c` (isosurface engine), `C/datagrid.c` (3D/2D scalar fields), `C/colorplane.c` (2D contour), `C/fs.c` + `C/cryDispFuncMultiFS.c` (Fermi surface), `F/fsReadBXSF.f` (BXSF reader), `F/recvec.f`, `F/pwKPath.f`, `F/kPath.f`, `F/wigner.f` (BZ/k-path math), `C/xcBz.c` + `C/bz.h`.
