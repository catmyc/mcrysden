# mcrysden roadmap

Last updated: **2026-07-15 (v1.1.13 shipped)**.

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
- [x] 153 tests: unit, snapshot (FNV-1a pixel hash vs. committed goldens), diagnostic, model-layer cache tests (incl. BZ cache + BZ-visible-for-slab render tests + force-arrow render test). `MCRYSDEN_REGENERATE=1` regenerates goldens.

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
