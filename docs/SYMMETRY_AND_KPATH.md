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

Two additional export formats are available as of v1.1.31:

- **QE `K_POINTS crystal_b` card body** (`KPathExport.qeKPointsCrystalB`). Official bands-card syntax: one row per route point `kx ky kz w`, where `w` is the number of subdivisions into the next point and coordinates are fractional in the input reciprocal basis. The exporter and the UI write the card body only — no caller adds the card line, so the user must place the output immediately after the `K_POINTS crystal_b` card line in the input file. The fourth column is written as `w = n − 1` for the edge's endpoint-inclusive sample count `n` (2…200, apportioned by edge length within each component exactly as the editor's interpolation allocates), so QE's `generate_k_along_lines` output count matches the editor's interpolated points for every edge. A line crossing a route break gets weight 0, which QE officially treats as a jump emitting only the next row's point, so disconnected components are not silently connected. The final row's weight is written 0 and ignored by QE. Routes with fewer than two points, over the 1,024-node cap, or with non-finite coordinates are rejected before output.
- **Wannier90 `kpoint_path` block** (`KPathExport.wannier90KPointPath`). Official `begin kpoint_path` / `end kpoint_path` syntax with one row per connected edge (`label1 x1 y1 z1 label2 x2 y2 z2`). Disconnected components yield non-sharing rows, so breaks are preserved without any special encoding. Labels are sanitized to a single whitespace-free token capped at 64 characters, with Wannier90 comment characters `!` and `#` replaced by `_` so they can never start a comment in the exported file; blank/whitespace labels receive deterministic generated labels `K1`, `K2`, … by stable route index, so a shared endpoint carries the same generated label in both adjacent rows. Routes with fewer than two points, over the 1,024-node cap, no connected edge at all, orphan singleton components (route points belonging to no edge), or non-finite coordinates are rejected.
- **Sidebar actions.** All five formats are offered in two rows — QE (.pwscf), QE crystal_b, Wannier90, then kpf and VASP — with per-format default filenames (`kpath.qe`, `kpath.crystal_b`, `kpath.win`, `kpath.kpf`, `KPOINTS`) and save-panel wiring; a button that cannot encode the current route is disabled with an explanatory tooltip.

## Import behavior

Routes can be imported from QE `K_POINTS crystal` cards, VASP line-mode `KPOINTS` files, Wannier90 `kpoint_path` blocks, and XCrySDen `.kpf` files, via the sidebar "Import…" panel or `mcrysden <structure> --kpath <file>`. Format detection uses extension/filename hints first (`kpf`, exact `KPOINTS`) and then content sniffing (`K_POINTS` card, `kpoint_path` block, or the VASP line-mode layout); anything else is rejected as unsupported. A UTF-8 BOM is stripped before detection and parsing, and CRLF files parse identically to LF.

- All coordinates are read as fractional (crystal) coordinates in the conventional reciprocal basis. QE data lines may carry an optional weight column (validated but not stored). VASP Cartesian line-mode and QE `automatic`/`tpiba_b`/`gamma` grid cards are rejected with a clear "not a band path" diagnostic.
- VASP line-mode files carry an explicit points-per-segment integer N, which becomes the imported route's `pointsPerSegment` clamped to the editor range 2…200. QE, Wannier90, and KPF imports synthesize the default of 20. The sampling density propagates to the sidebar/CLI preference **only** for VASP files; importing QE, Wannier90, or KPF never clobbers a sampling preference restored from `.mvis-state` or set by the user. A CLI `--kpath` import is applied after any companion `.mvis-state` route, so the flag always wins for the route while preserving the non-VASP sampling preference.
- VASP k-point labels are preserved from a bare fourth column or, when the file uses the app's own export style, as the first token after the earliest `!`/`#` comment marker on the line.
- Wannier90 parsing follows the documented interleaved form: an explicit `begin kpoint_path` / `end kpoint_path` block (inline `!`/`#` comments allowed on the delimiter lines; an unterminated block is rejected) whose rows are `label1 x1 y1 z1 label2 x2 y2 z2`. The legacy `label1 label2 x1 y1 z1 x2 y2 z2` layout is also accepted per row, and a legacy bare `kpoint_path` header must match exactly (no fuzzy substring) and ends at the next keyword line or scalar assignment. Malformed, ambiguous, or non-numeric-label rows fail with a descriptive error instead of being skipped.
- Consecutive VASP/Wannier90 segments that share an endpoint (within 1e-4 per component) coalesce into one continuous route; non-sharing consecutive segments receive a break index, matching the disconnected-route model above.
- KPF files are a flat ISS-scaled point list with no break syntax, so imported KPF routes are always fully connected.
- Imported routes are marked `userEdited` with the generated signature cleared, so they are never auto-regenerated when the structure changes, and they participate in undo exactly like manual edits.
- Parsing is bounded: files over 16 MB, routes over 1,024 nodes, non-finite coordinates/weights, malformed counts, and unsupported formats fail with a descriptive error instead of trapping.

## Reciprocal editor UX (v1.1.25)

The interactive k-path editor surfaces the following behavior:

- **Physical distances.** Incoming and cumulative route distances are reported in Å⁻¹ using the conventional reciprocal metric and are break-aware across disconnected components.
- **Cached bounded BZ candidates.** BZ landmark candidates (Γ, vertices, edge midpoints, face centers) are computed from the cached bounded BZ and reused across picks.
- **Hover tooltip.** `NSTrackingArea` hover over a candidate shows a transient tooltip with the point label and fractional coordinates.
- **Viewport node labels and selected style.** Route nodes are labeled in the viewport; the selected node uses a distinct style (amber route, cyan node, selected-route-node highlight).
- **Accessibility and keyboard navigation.** AppKit button elements expose visible BZ landmark candidates to VoiceOver; arrow keys cycle candidates, and Space or Return appends the focused candidate to the route.
- **Automatic BZ framing.** A one-shot editor entry frames the BZ (`BZPresentation.framedCamera`) and restores the previous camera, display, and BZ visibility on exit.
- **Nonfatal unavailable status.** When the BZ cannot be constructed (incomplete cell, malformed geometry), the editor reports an unavailable state instead of trapping.
- **Export filtering.** Route labels are exported with the canvas; the transient hover tooltip is excluded.
- **BZ construction.** The BZ is built using bounded, scale-safe Double arithmetic with an adaptive G-star completeness proof and bounded construction budgets.

## Verification

Run the project verification sequence on macOS:

```bash
swift build
swift test
zsh scripts/smoke.sh
```

The tracked suite contains 98 tests as of v1.1.33. The smoke script performs a release build and a headless export to `/tmp/mcrysden_smoke.png`.
