# Crystal symmetry and canonical k-paths

This document records the implemented symmetry and high-symmetry-path contract. The current source, `Package.swift`, CI commands, and tests remain authoritative if an older design document disagrees.

## Analysis boundary

`CrystalSymmetryAnalyzer` analyzes complete, three-dimensional periodic structures with a finite, nonsingular cell and at least one atom. The default and currently used `symprec` is `1e-5` Å; callers may request values from `1e-8` through `1e-1` Å. Analysis is synchronous and is capped at 4,096 input atoms, 4,096 operations, and 400,000 standardized-conventional atoms.

Known asymmetric-unit-only inputs are not silently treated as complete crystals. CIF or CRYSCAL data that has not been expanded to the full cell reports symmetry as unavailable. Invalid cells, coordinates, types, tolerances, and oversized structures likewise produce an unavailable reason instead of a partial result or retry at a different tolerance.

The vendored spglib 2.7.0 sources live in `Sources/SpglibCore`. `Sources/MolEnvSpglib` is the allocation-safe project façade: it copies results into project-owned values and releases spglib allocations before returning to Swift. It exposes no retained spglib pointers.

## Cells and coordinate conventions

Direct-cell basis vectors are stored as the rows `a`, `b`, and `c`. Reciprocal vectors include the `2π` factor. Symmetry analysis keeps the following concepts distinct:

- the loaded input cell, whose reciprocal fractional coordinates drive the viewport, editor, state file, and export;
- spglib's detected and standardized primitive/conventional cells;
- the HPKOT pre-idealized and idealized conventional frames used to select a path variant; and
- the HPKOT primitive frame in which canonical special-point tables are defined.

`CanonicalPathGenerator` selects the HPKOT path in its canonical frame and maps its Cartesian reciprocal vectors back to fractional coordinates in the loaded input cell. A rotated or crystallographically equivalent input therefore renders and exports the same physical path without replacing the user's structure orientation.

## HPKOT/SeekPath coverage

`HPKOT.swift` implements the SeekPath 2.1 `hpkot` recipe and data for all 29 extended Bravais variants. This includes metric-dependent monoclinic, orthorhombic, tetragonal, rhombohedral, and triclinic branches. Triclinic selection performs the required Niggli reduction and retains the transform needed to return the path to the input basis.

The implementation is checked against `Sources/MolVisAppTests/Fixtures/hpkot_oracle.json`, an exact SeekPath-derived oracle covering every variant. Additional tests rotate and permute representative cells to catch frame-dependent variant or coordinate errors.

SeekPath-derived data and logic are distributed under the MIT license in `SEEKPATH_LICENSE.txt`, also packaged at `Sources/MolVisApp/Resources/SEEKPATH_LICENSE.txt`. Vendored spglib license material remains with `Sources/SpglibCore`.

## Disconnected route model

A `KPath` contains ordered points and a set of break indices. A break at index `i` means there is no edge from point `i` to point `i + 1`. Connected components are interpolated independently, and even a one-point component is retained as an explicit k-point.

`pointsPerSegment` is a budget per connected component. Within a component it is divided among edges in proportion to their reciprocal-space lengths. Every explicit endpoint is retained when the global one-million-point safety cap permits it; later components are not starved by an earlier dense component.

The renderer, editor, and state model use the same break convention. Sidebar route mutations update points and breaks atomically, and deleting a node repairs adjacent boundaries instead of accidentally connecting components.

## Lifecycle and persistence

Routes have either `generated` or `userEdited` provenance:

- A freshly parsed crystal receives a generated canonical route and structure signature.
- A physical geometry or animation-frame change uses the freshly generated route for the new structure.
- Display-only supercell and slab operations do not replace the route.
- A user-edited route is remapped from the old to the new input reciprocal basis through Cartesian reciprocal space. If either basis is unusable, the literal fractional coordinates are preserved as the non-destructive fallback.

The flat `.mvis-state` format persists `kPathPoints`, `kPathBreaks`, `kPathProvenance`, optional generated `kPathSignature`, and `kPathInputCell`. Loading validates these fields transactionally. Older state files without the newer keys remain connected and use the legacy-compatible route policy.

## Export behavior

Quantum Espresso `K_POINTS crystal` export can represent the interpolated points from disconnected components and preserves explicit singleton components. VASP line-mode `KPOINTS` export uses endpoint pairs and blank lines between segments; singleton components are rejected because line mode cannot represent them. XCrySDen KPF has no syntax for a disconnected boundary, so the UI disables that export for disconnected routes and the exporter rejects a programmatic request with a clear error.

## Verification

Run the project verification sequence on macOS:

```bash
swift build
swift test
zsh scripts/smoke.sh
```

The tracked suite contains 858 tests as of v1.1.23. The smoke script performs a release build and a headless export to `/tmp/mcrysden_smoke.png`.
