# mcrysden roadmap

Last updated: **2026-07-11 (v1.1.2 shipped)**.

Status legend: `[x]` done · `[~]` partly done · `[ ]` todo. "file" = an example input is on hand for immediate test.

## Implemented in v1.1.2

### File formats
- [x] XSF (structure only — `DATAGRID` blocks are rejected), AXSF animation
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
- [x] 76 tests: unit, snapshot (FNV-1a pixel hash vs. committed goldens), diagnostic, model-layer cache tests (incl. BZ cache + BZ-visible-for-slab render tests). `MCRYSDEN_REGENERATE=1` regenerates goldens.

## Half-done (mechanism exists, UI missing)
- [~] **Save-state menu item** — `StateStore.save` writer is implemented and load is wired to the CLI and headless export, but there is **no menu item or button** to trigger a save from the GUI. A one-line UI hook onto the existing writer.
- [~] **`--pwo` / `--out` to AXSF conversion reuse** — `.pwo` already produces animation frames; could back a `pwo2xsf`-style command.

## Next up — prioritized by available test fixtures

Ranked so that every item can be **tested immediately** from example files that already exist on disk (project `Assets/` + the XCrySDen example suite under this machine's `metal_restruct_xcrysden/examples/`). Features with no local fixture are deferred further down.

### Tier A — ready to test today (input files on hand)

| # | Feature | Test fixtures on disk | Notes |
|---|---------|-----------------------|-------|
| 1 | **Volumetric isosurface engine** (un-reject `DATAGRID_3D` in XSF; marching-cubes/tetrahedra; iso-value slider; gradient normals; transparency; clip) | `Assets/volumetric_grid.xsf` (3D Si charge density — already in the repo, currently rejected), `CO_homo.xsf.gz`, `CO_lumo.xsf.gz`, `oxirane_homo.xsf.gz`, `mol-urea.xsf.gz` (molecular orbitals), `mol-urea2D.xsf` (2D grid) | Biggest visual gap. The fixture in the repo makes the first milestone (parse a 3D grid into a float buffer) testable with a shipped file. |
| 2 | **Gaussian `.cube` / `.g98` reader** | `N2O_homo+lumo.cube.gz`, `benzene.g98_out`, `benzene-6CH3-OCH3.g98` (+ reference script `g98cube.tcl`) | `.cube` is the lingua franca of volumetric chem data; reuses the field buffer from #1. |
| 3 | **Fermi-surface reader** (BXSF binary, crop-to-Brillouin-zone, multi-surface) | `MgB2.bxsf.gz`, `RhBulkFcc.bxsf.gz` | Clean binary format; a 2-band case and a metallic bulk case. |
| 4 | **Color-plane / 2D-contour rendering** (slice a 3D field along a plane) | `mol-urea2D.xsf` (2D grid), reference scripts `colorplane_animation.tcl`, `contours.tcl` | Falls out once the datagrid + field buffer from #1 exist. |
| 5 | **Band-structure extraction** (QE k-point + eigenvalue block → line graph) | `CH3Rh111.out`, `EthAl001-2x2.out` both contain `bands (ev):` eigenvalue blocks | Needs a dedicated band reader (the `.pwo` parser reads geometry, not bands) plus a 2D line-graph layer. |
| 6 | **WIEN2k `.struct` reader** | 24 files (`gaas.struct`, `si111.struct`, `cr2o3.struct`, `mos2.struct`, …) | Dominant solids DFT code; broad chemistry coverage. |
| 7 | **CRYSTAL `.r1` reader** | 16 files (`Pt322`, `ZnS`, `corundum`, `graphite`, `rutile`, `calcite`, `urea`, `zro2`, …) | Periodic quantum-chem code. |
| 8 | **Orca `.out` reader** | `pbe.accOpt.AsF2-C2C2.out.gz` | Key quantum-chem code; one sample to start. |
| 9 | **FHI-aims / FHI98MD reader** | `GaAsSurface_coord.out` + `GaAs_inp.ini`, `GaAsSurface_inp.ini` | Format documentation bundled. |
| 10 | **Force / stress / energy readouts + force arrows** | `CH3Rh111.out` carries per-atom `Forces acting on atoms`, `Total force`, `! total energy` | `Atom` stores no force field — needs a struct change + readout + arrow rendering. |

### Tier B — needs another engine first

| # | Feature | Blocker |
|---|---------|---------|
| 11 | **Density of states (DOS)** plot (total + projected) | Needs #5's band/DOS reader **and** the 2D Grapher layer. No local `projwfc`/`dos.x` output to test against (would have to be generated/downloaded). |

### Tier C — no local test fixtures (capability / UI, validated by interaction)

These are real gaps but can't be driven from an example file; they're validated by operating the UI.
- [ ] **Structure editing**: cut cluster/molecule; substitute / remove / insert / displace atoms; elastic cell deformation; multi-slab; undo-redo stack (ref `Tcl/menu.tcl`).
- [ ] **On-screen bond distance labels** — live distance text above each bond (no code yet).
- [ ] **Image/gradient background: image variant** — only `solid` + `gradient_top` exist; picture-background not implemented.
- [ ] **Print** of the view (`NSPrintOperation`).
- [ ] **Stereo / anaglyph** rendering.
- [ ] **Tcl scripting engine** — the `.xcrysden`/`.tcl` files are *output* (saved state / usage illustrations), so they can't re-run as test specs; validating an interpreter needs a written test suite.
- [ ] **External-code converters** (`pwi2xsf`, `pwo2xsf`, `struct2xsf`, …) — the programs that produce XSF for formats mcrysden can't read natively.

## Reference: what XCrySDen implements

Authoritative gap list is against XCrySDen 1.6.2. Reference algorithms live in its tarball: `C/MarchCubes.c`, `C/polygonise.c`, `C/isosurf.c`, `C/isoline.c` (isosurface engine), `C/datagrid.c` (3D/2D scalar fields), `C/colorplane.c` (2D contour), `C/fs.c` + `C/cryDispFuncMultiFS.c` (Fermi surface), `F/fsReadBXSF.f` (BXSF reader), `F/recvec.f`, `F/pwKPath.f`, `F/kPath.f`, `F/wigner.f` (BZ/k-path math), `C/xcBz.c` + `C/bz.h`.
