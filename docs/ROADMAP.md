# mcrysden roadmap

Last updated: 2026-07-09 (v1.2.0 in progress).

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done.

## Tier 1 — quick wins (polish)

- [x] QE `.pwi/.in/.inp` parser (all 17 ibrav)
- [x] Force-parser CLI flags (`--xsf/--xyz/--pdb/--axsf/--pwi/--cif/--poscar`)
- [x] Pan (option-drag)
- [x] True 2D line/point modes
- [x] Gradient / image background
- [x] Lighting & material sliders (ambient/diffuse/specular/shininess/light direction)
- [x] World-space lighting
- [x] Slab plane h/k/l exposed in sidebar
- [x] `--frame` flag + AXSF animation playback UI
- [x] On-screen bond distance labels
- [x] Save-state menu item
- [x] More snapshot goldens + a slab/2D render test
- [x] Reset View button

## Tier 2 — capability unlocks (weeks)

- [x] CIF reader
- [x] POSCAR / CONTCAR (VASP) reader
- [x] Proper polyhedral mode (Voronoi / half-space intersection)
- [x] Lighting material shader term (Blinn-Phong specular)
- [x] Vector export (PS/EPS/PDF/SVG) alongside PNG

## Tier 3 — v2 surface (large)

### Next (this session)

- [~] QE PWscf output (`.pwo`) parser — read final cell, atomic positions (bohr/alat/crystal/angstrom), PRIMVEC/CONVVEC via ibrav, forces/energy if present; native C `parse_pwo` (sibling of `parse_pwi`), no shell filter. See `F/pwo_xsf2xsf.f`, `F/pwi2xsf.f` for conventions.
- [~] Brillouin-zone + k-path tooling — reciprocal lattice, BZ polyhedron (Wigner-Seitz), high-symmetry k-points per ibrav, k-path generation through special points; Swift + a small C math helper for recvec/BZ geometry. See `F/recvec.f`, `F/pwKPath.f`, `F/kPath.f`, `F/wigner.f`, `C/xcBz.c`, `C/bz.h`.

### Later (deferred)

- [ ] QE `.pwo` follow-ups: multi-step relaxations/MD as AXSF animation frames; forces/stress/energy readouts.
- [ ] Isosurface engine (marching cubes + tetrahedra, gradient normals, transparency, clip). See `C/MarchCubes.c`, `C/polygonise.c`, `C/isosurf.c`, `C/isoline.c`.
- [ ] 3D scalar-field parsing (un-reject `DATAGRID_3D` in XSF). See `C/datagrid.c`, `Tcl/parseDataGrid.tcl`.
- [ ] Color-plane / 2D contour rendering. See `C/colorplane.c`.
- [ ] Fermi surface (BXSF reader, crop-to-BZ, multi-surface). See `F/fsReadBXSF.f`, `C/fs.c`, `C/cryDispFuncMultiFS.c`.
- [ ] Band structure + DOS graphs (Grapher) — depends on k-path + a band-data reader.
- [ ] Structure editing (cut cluster/molecule, substitute/remove/insert/displace atoms, elastic deformation, multi-slab, undo/redo). See `Tcl/menu.tcl`.
- [ ] External-code converters (QE pwi2xsf/pwo2xsf, WIEN2k, CRYSTAL, Gaussian .cube, FHI98MD, Orca).
- [ ] Scripting language (`scripting.tcl` equivalent).
- [ ] Stereo / anaglyph.
