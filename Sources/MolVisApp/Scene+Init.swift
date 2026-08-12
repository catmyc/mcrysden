import Foundation
import simd
import MolEnvParse

extension Scene {
    /// Compute a distance / angle / dihedral from selected atoms.
    /// pick order matters: angle uses the middle atom as vertex; dihedral is
    /// signed by the plane normals of (a,b,c) and (b,c,d).
    static func computeMeasurement(mode: MeasurementMode, atoms: [Atom], selected: [Int],
                                   cell: Cell? = nil, periodicDim: Int = 0) -> MeasurementResult? {
        guard mode != .none, selected.count == mode.selectionCap,
              selected.allSatisfy({ $0 >= 0 && $0 < atoms.count }) else { return nil }
        let sel = selected.map { atoms[$0].coord }
        guard sel.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        var value: Float = 0
        switch mode {
        case .distance:
            if let cell = cell {
                guard let d = PeriodicGeometry.minimumImageDistance(from: sel[0], to: sel[1],
                                                                      cell: cell, periodicDim: periodicDim) else { return nil }
                value = d
            } else {
                value = length(sel[1] - sel[0])
            }
        case .angle:
            if let cell = cell, cell.isFinite, periodicDim > 0 {
                guard let angle = PeriodicGeometry.minimumImageAngle(
                    a: sel[0], b: sel[1], c: sel[2],
                    cell: cell, periodicDim: periodicDim) else { return nil }
                value = angle
            } else {
                let d0 = sel[0] - sel[1], d2 = sel[2] - sel[1]
                guard length(d0) > 1e-8, length(d2) > 1e-8 else { return nil }
                let v0 = normalize(d0), v2 = normalize(d2)
                value = acos(min(max(dot(v0, v2), -1), 1)) * 180 / .pi
            }
        case .dihedral:
            if let cell = cell, cell.isFinite, periodicDim > 0 {
                guard let dihedral = PeriodicGeometry.minimumImageDihedral(
                    a: sel[0], b: sel[1], c: sel[2], d: sel[3],
                    cell: cell, periodicDim: periodicDim) else { return nil }
                value = dihedral
            } else {
                let d0 = sel[0] - sel[1], d1 = sel[1] - sel[2], d2 = sel[2] - sel[3]
                guard length(d0) > 1e-8, length(d1) > 1e-8, length(d2) > 1e-8 else { return nil }
                let ba = normalize(d0), cb = normalize(d1), dc = normalize(d2)
                let n1 = cross(ba, cb), n2 = cross(cb, dc)
                guard length(n1) > 1e-8, length(n2) > 1e-8 else { return nil }
                value = acos(min(max(dot(normalize(n1), normalize(n2)), -1), 1)) * 180 / .pi
            }
        case .none:
            return nil
        }
        guard value.isFinite else { return nil }
        let idxStr = selected.map { "\($0 + 1)" }.joined(separator: "-")
        let unit = (mode == .distance) ? "Å" : "°"
        let summary = "\(mode.label) (\(idxStr)): \(String(format: mode == .distance ? "%.3f" : "%.1f", value)) \(unit)"
        return MeasurementResult(mode: mode, atomIndices: selected, value: value, summary: summary)
    }

    init(loaded: LoadedScene, displayMode: DisplayMode = .ballStick) {
        self.atoms = loaded.atoms
        self.bonds = loaded.bonds
        self.cell = loaded.cell
        self.title = loaded.title
        self.displayMode = displayMode
        self.isCrystal = loaded.isCrystal
        self.periodicDim = loaded.periodicDim
        self.scalarField = loaded.scalarField
        self.fermiSurface = loaded.fermiSurface
        self.bandStructure = loaded.bandStructure
        self.densityOfStates = loaded.densityOfStates
        self.grid2D = loaded.grid2D
        // Forces/energy/stress parsed from a QE output (final SCF iteration);
        // nil for non-QE files. `loaded.atoms[i].force` already carries per-atom
        // arrows aligned by the printed index below.
        self.forceSet = loaded.forceSet
        // Multi-orbital cube files: retain every orbital grid so the user can
        // switch between them. `scalarField` above is already the first orbital.
        self.multiOrbitalFields = loaded.multiOrbitalFields
        self.baseAtoms = loaded.atoms
        self.baseBonds = loaded.bonds
        // Seed the editable k-path with the generated high-symmetry default for
        // crystals; molecules keep an empty route. Edited by the k-path editor.
        // The path is generated from the symmetry analysis (which runs below),
        // so we defer generation to `installCanonicalPath(for:)`.
        self.kPathPoints = []
        self.kPathBreaks = []
        self.kPathProvenance = .generated
        self.kPathSignature = nil
        self.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: loaded.cell,
            atoms: loaded.atoms,
            isCrystal: loaded.isCrystal,
            periodicDim: loaded.periodicDim,
            inputCompleteness: loaded.symmetryInputCompleteness
        )
        // Install the canonical path from the just-computed symmetry analysis.
        if loaded.isCrystal, let cell = loaded.cell {
            self.installCanonicalPath(cell: cell)
        }
    }

    /// Install the canonical high-symmetry path for the current symmetry.
    /// Maps the path from the standardized reciprocal basis to the input-cell
    /// reciprocal basis. Sets the provenance to `.generated` and records the
    /// structure signature so future operations can detect when regeneration
    /// is needed. No-op when symmetry is unavailable.
    mutating func installCanonicalPath(cell: Cell) {
        guard let symmetry = crystalSymmetry?.symmetry else {
            kPathPoints = []
            kPathBreaks = []
            kPathProvenance = .generated
            kPathSignature = nil
            return
        }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical,
                                                                  symmetry: symmetry,
                                                                  inputCell: cell)
        kPathPoints = mapped.kPoints
        kPathBreaks = mapped.breaks
        kPathProvenance = .generated
        kPathSignature = CanonicalPathGenerator.structureSignature(for: crystalSymmetry?.symmetry)
    }

    /// Transfer a route from a scene that is being replaced by a freshly parsed
    /// structure/frame.  A freshly parsed `Scene` has already generated its own
    /// canonical route in its *current input reciprocal basis*, so generated
    /// routes deliberately stay here rather than copying stale fractional values
    /// from the old frame.  This covers both a real structure change and a pure
    /// physical rotation of the input cell (which leaves the standardized
    /// signature unchanged but changes the meaning of fractional coordinates).
    ///
    /// A user route is data, not a request to regenerate.  When both input cells
    /// provide finite, invertible reciprocal bases, preserve each point's
    /// Cartesian reciprocal position by mapping old fractional coordinates into
    /// the new basis.  If that mathematics is unavailable (e.g. a malformed or
    /// non-periodic replacement), preserve the exact stored fractional route
    /// instead of dropping or inventing a route.  The latter is the explicit
    /// non-destructive fallback policy.
    mutating func transferKPathAcrossGeometryChange(from previous: Scene) {
        guard previous.kPathProvenance == .userEdited else {
            // `self` is the freshly parsed scene. Its generated points, breaks,
            // and signature are authoritative for the current geometry.
            return
        }

        if let oldCell = previous.cell, let newCell = cell,
           let remapped = Self.remapKPathPoints(previous.kPathPoints,
                                                 from: oldCell, to: newCell) {
            kPathPoints = remapped
        } else {
            // See the method documentation: no valid old/new reciprocal mapping
            // means preserve the user's literal coordinates unchanged.
            kPathPoints = previous.kPathPoints
        }
        kPathBreaks = previous.kPathBreaks
        kPathProvenance = .userEdited
        // A structure signature describes a generated route only. Never carry a
        // stale generated signature onto a user-edited route.
        kPathSignature = nil
    }

    /// Map route coordinates from one input reciprocal basis to another while
    /// retaining Cartesian reciprocal positions. Returns nil when either basis
    /// is unusable or any coordinate would become non-finite; callers use the
    /// documented non-destructive literal-coordinate fallback in that case.
    static func remapKPathPoints(_ points: [KPoint], from oldCell: Cell,
                                 to newCell: Cell) -> [KPoint]? {
        guard points.allSatisfy({ $0.frac.x.isFinite && $0.frac.y.isFinite && $0.frac.z.isFinite }) else {
            return nil
        }
        guard let basesMatch = inputReciprocalBasesMatch(oldCell, newCell) else {
            return nil
        }
        // Avoid a needless inverse/multiply round trip (and the associated tiny
        // Float drift) when atom positions changed but the input basis did not.
        guard !basesMatch else { return points }

        let oldReciprocal = oldCell.reciprocalVectors
        let newReciprocal = newCell.reciprocalVectors
        var result: [KPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            let cartesian = BrillouinZone.cartesianFromFractional(point.frac,
                                                                    reciprocal: oldReciprocal)
            guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite,
                  let fractional = BrillouinZone.fractionalFromCartesian(cartesian,
                                                                          reciprocal: newReciprocal) else {
                return nil
            }
            result.append(KPoint(fractional, point.label))
        }
        return result
    }

    /// Whether two direct input cells induce the same reciprocal basis. A nil
    /// result means at least one basis is non-finite or singular, so it is not
    /// safe to make a coordinate-space assertion about them.
    static func inputReciprocalBasesMatch(_ lhs: Cell, _ rhs: Cell,
                                          relativeTolerance: Float = 1e-5) -> Bool? {
        let left = lhs.reciprocalVectors
        let right = rhs.reciprocalVectors
        let leftMatrix = simd_float3x3(columns: (left.a, left.b, left.c))
        let rightMatrix = simd_float3x3(columns: (right.a, right.b, right.c))
        guard BrillouinZone.isFiniteInvertible(leftMatrix),
              BrillouinZone.isFiniteInvertible(rightMatrix) else {
            return nil
        }
        for (a, b) in [(left.a, right.a), (left.b, right.b), (left.c, right.c)] {
            let scale = max(length(a), length(b))
            guard scale.isFinite, scale > 0, length(a - b) <= relativeTolerance * scale else {
                return false
            }
        }
        return true
    }

    var centroid: SIMD3<Float> {
        guard !atoms.isEmpty else { return SIMD3(0,0,0) }
        var sum = SIMD3<Float>.zero
        for a in atoms { sum += a.coord }
        return sum / Float(atoms.count)
    }

    func boundingSphere() -> (center: SIMD3<Float>, radius: Float) {
        let c = centroid
        var r: Float = 0
        for a in atoms { r = max(r, distance(a.coord, c)) }
        return (c, r)
    }

    /// Camera framing sphere that covers BOTH the atoms AND any volumetric grid
    /// (scalar field or Fermi surface). A structure-less file (e.g. a BXSF with
    /// only a Fermi grid) would otherwise frame a zero-radius point at the origin
    /// and the surface would render invisibly tiny. The grid extent is derived
    /// from its span vectors: sample (0,0,0)==origin, (nx,ny,nz)==origin+sum(vec).
    func framingSphere() -> (center: SIMD3<Float>, radius: Float) {
        var minCorner = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxCorner = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var hasAny = false
        for a in atoms {
            minCorner = min(minCorner, a.coord); maxCorner = max(maxCorner, a.coord); hasAny = true
        }
        func incorporate(_ o: SIMD3<Float>, _ v: [SIMD3<Float>]) {
            // The grid occupies the parallelepiped whose 8 corners are
            // o + i*v[0] + j*v[1] + k*v[2] for i,j,k in {0,1}. When a span vector has
            // negative components (e.g. RhBulkFcc) the min corner is NOT origin but
            // origin plus the summed negative extents, so accumulate per-axis.
            var mn = o, mx = o
            for corner in [(0,0,0),(1,0,0),(0,1,0),(0,0,1),(1,1,0),(1,0,1),(0,1,1),(1,1,1)] {
                let p0 = o + v[0] * Float(corner.0)
                let p1 = p0 + v[1] * Float(corner.1)
                let p  = p1 + v[2] * Float(corner.2)
                mn = min(mn, p); mx = max(mx, p)
            }
            minCorner = min(minCorner, mn); maxCorner = max(maxCorner, mx); hasAny = true
        }
        if let f = scalarField { incorporate(f.origin, f.vec) }
        if let fs = fermiSurface, let b = fs.bands.first { incorporate(b.origin, b.vec) }
        guard hasAny else { return (SIMD3<Float>.zero, 0) }
        let center = (minCorner + maxCorner) * 0.5
        let radius = distance(maxCorner, minCorner) * 0.5
        return (center, radius)
    }

    /// Camera that frames both atoms AND any volumetric grid, used as the single
    /// The radius of the scene's framing sphere (atoms + any volumetric grid).
    /// Used to compute depth-cueing ranges. Returns 0 for an empty scene.
    func boundingSphereRadius() -> Float { framingSphere().radius }

    /// Camera that frames both atoms AND any volumetric grid, used as the single
    /// source of truth by the live window and both exporters. Atomic scenes are in
    /// Å (floored at 8); reciprocal-space grids (BXSF) span only ~0.2 units, so the
    /// floor would leave the camera way too far and the surface invisibly small — fit
    /// those tightly. This guarantees a structure-less BXSF exports at the framing it
    /// displays as in the GUI.
    func defaultCamera() -> Camera {
        var c = Camera()
        let (cen, r) = framingSphere()
        c.center = cen
        c.distance = atoms.isEmpty ? max(0.5, r * 3) : max(8, r * 3)
        return c
    }

    static let superCellAtomCap = 500_000

    func widenSuperCell(_ sc: SuperCell) -> Scene {
        guard let cell else { return self }
        // Overflow-safe, positive supercell product: a raw n1*n2*n3 wraps on
        // overflow (silently passing the cap check) and a zero/negative factor is
        // nonsensical. Refuse (returning self) rather than expand.
        guard let total = Scene.positiveProduct(sc.n1, sc.n2, sc.n3) else { return self }
        // When reducing to (1,1,1) restore the pristine base set. If there is NO
        // pristine set (manual scene, baseAtoms empty) keep the current atoms so
        // the identity operation does not wipe a hand-built structure.
        if total <= 1 {
            var out = self
            // An existing base atom snapshot is the sentinel for a pristine
            // geometry. Its bond snapshot may intentionally be empty, so do not
            // use bond emptiness to decide whether it is present.
            let hasBaseSnapshot = !baseAtoms.isEmpty
            out.atoms = hasBaseSnapshot ? baseAtoms : atoms
            out.bonds = hasBaseSnapshot ? baseBonds : bonds
            out.preslabAtoms = out.atoms
            out.superCell = SuperCell()
            // Shrinking to (1,1,1) restores the base atom set; selection indices into
            // the previous (widened) set are now stale. Leave them only when the set
            // is genuinely unchanged (a hand-built scene snaps back to `atoms`).
            if out.atoms != atoms {
                out.selectedAtoms = []
                out.measurementResult = nil
            }
            // Shrinking to (1,1,1) restores the base atom set but keeps the base
            // cell and its reciprocal structure. Both generated and user-edited
            // paths remain valid — no mutation needed.
            return out
        }
        // Always expand from the base atoms so the operation is idempotent
        // and reversible: calling widen(2) → widen(1) returns the original.
        let src = baseAtoms.isEmpty ? atoms : baseAtoms
        let projected = total.multipliedReportingOverflow(by: src.count)
        if projected.overflow || projected.partialValue > Scene.superCellAtomCap {
            print("[mcrysden] warning: supercell \(sc.n1)×\(sc.n2)×\(sc.n3) would exceed \(Scene.superCellAtomCap) atom cap (\(total)×\(src.count)); refused")
            return self
        }
        // 1D/2D structures replicate only along their periodic axes. Expanding a
        // non-periodic axis (e.g. n3 > 1 for a 2D slab whose c is a vacuum gap)
        // produces physically invalid replicas. Refuse any factor > 1 along a
        // non-periodic dimension. Periodic axes: a = n1 for dim 1; a,b = n1,n2
        // for dim 2. The (1,1,1) shrink path and cap checks above are untouched.
        if periodicDim < 3 {
            if periodicDim == 1 {
                if sc.n2 > 1 || sc.n3 > 1 {
                    print("[mcrysden] warning: supercell \(sc.n1)×\(sc.n2)×\(sc.n3) refused for a 1D structure: only n1 may exceed 1")
                    return self
                }
            } else if periodicDim == 2 {
                if sc.n3 > 1 {
                    print("[mcrysden] warning: supercell \(sc.n1)×\(sc.n2)×\(sc.n3) refused for a 2D structure: only n1 and n2 may exceed 1")
                    return self
                }
            }
        }
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(projected.partialValue)
        for i in 0..<sc.n1 { for j in 0..<sc.n2 { for k in 0..<sc.n3 {
            let t = cell.a * Float(i) + cell.b * Float(j) + cell.c * Float(k)
            for a in src {
                // Each supercell replica carries the same force as its base atom
                // (physically periodic), so arrows repeat correctly across the cell.
                newAtoms.append(Atom(coord: a.coord + t, atomicNumber: a.atomicNumber,
                                     label: a.label, force: a.force))
            }
        }}}
        var out = self
        out.atoms = newAtoms
        // Bond against the finite displayed supercell, not the primitive cell.
        // Otherwise every translated copy is compared through the primitive
        // minimum image and produces duplicate/phantom cross-image matches.
        let bondCell = Self.bondCell(cell, superCell: sc, periodicDim: periodicDim)
        out.bonds = Self.rebond(newAtoms, cell: bondCell, isCrystal: true, periodicDim: periodicDim)
        out.preslabAtoms = newAtoms    // snapshot for `applySlab`
        out.superCell = sc
        // For a hand-built scene (no pristine base yet), snapshot the pre-expansion
        // source atoms/bonds as the base so shrinking back (widen 1,1,1) recovers the
        // original instead of being stuck on the widened set.
        if baseAtoms.isEmpty {
            out.baseAtoms = src
            out.baseBonds = self.bonds
        }
        // Atom set was rebuilt; any selected indices and the locked measurement now
        // point at the wrong atoms.
        out.selectedAtoms = []
        out.measurementResult = nil
        // Supercell widening replicates atoms but keeps the base cell and its
        // reciprocal structure unchanged. The input-cell reciprocal basis is the
        // same, so BOTH generated and user-edited paths remain valid. No path
        // mutation is needed — generated paths stay generated, user paths stay
        // user-edited. (This is the key lifecycle invariant: display-only
        // replication must not destroy user-edited routes.)
        return out
    }

    /// Cell basis used by the bond pass for an explicitly displayed supercell.
    /// Non-periodic dimensions remain unscaled, even though their cell vector is
    /// retained as a vacuum/embedding vector for slab and polymer scenes.
    private static func bondCell(_ cell: Cell, superCell: SuperCell, periodicDim: Int) -> Cell {
        let n1 = periodicDim >= 1 ? max(1, superCell.n1) : 1
        let n2 = periodicDim >= 2 ? max(1, superCell.n2) : 1
        let n3 = periodicDim >= 3 ? max(1, superCell.n3) : 1
        return Cell(a: cell.a * Float(n1), b: cell.b * Float(n2), c: cell.c * Float(n3))
    }

    /// Return the directly displayed endpoint displacement for a bond.
    ///
    /// The C heuristic also records periodic-only matches whose translated atom
    /// is outside the explicitly displayed finite image set. Those records stay
    /// available for periodic detection/analysis, but renderers and labels must
    /// skip them. Explicit supercell replicas are rebonded against the scaled
    /// active cell and therefore appear as zero-image pairs.
    func directBondDisplacement(for bond: Bond) -> SIMD3<Float>? {
        guard bond.image == .zero,
              bond.i >= 0, bond.i < atoms.count,
              bond.j >= 0, bond.j < atoms.count else { return nil }
        let displacement = atoms[bond.j].coord - atoms[bond.i].coord
        return displacement.isFinite ? displacement : nil
    }

    /// Recompute bonds for the given atom set using the C covalent-radii
    /// heuristic (the same `make_bonds` that parsers call).
    ///
    /// `cell` may be nil for molecules (non-periodic structures); the C
    /// heuristic then uses `is_crystal = 0` so no minimum-image wrapping is
    /// applied. `isCrystal` and `periodicDim` select the correct bonding
    /// mode: crystals bond across periodic images (up to `periodicDim`
    /// dimensions); molecules bond purely by distance in free space.
    static func rebond(_ atoms: [Atom], cell: Cell?, isCrystal: Bool, periodicDim: Int) -> [Bond] {
        let nat = atoms.count
        guard nat > 0 else { return [] }

        // The C covalent-radii bond heuristic (make_bonds) is O(n^2) and refuses
        // structures above MOLENV_BOND_MAX_ATOMS (8000) — it returns no bonds and
        // sets a thread-local error. For big supercells/slabs this would silently
        // drop ALL bonds. Keep that degradation analytic: skip the expensive pass
        // above the cap, leave bonds empty (atoms and cell are untouched, so the
        // scene still renders), and warn rather than render a legal large
        // structure with zero bonds and no explanation.
        if nat > 8000 {
            print("[mcrysden] warning: \(nat)-atom structure exceeds the 8000-atom bond-heuristic cap; bonds omitted")
            return []
        }

        // Build a temporary MolEnvScene so we can call the C bond heuristic.
        let cAtoms = UnsafeMutablePointer<MolEnvAtom>.allocate(capacity: nat)
        for (i, a) in atoms.enumerated() {
            cAtoms[i].coord = (a.coord.x, a.coord.y, a.coord.z)
            cAtoms[i].atomic_number = Int32(a.atomicNumber)
            // label is char[8]; copy via pointer rebind
            withUnsafeMutablePointer(to: &cAtoms[i].label) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, 8)
                let len = min(7, a.label.utf8.count)
                for (j, byte) in a.label.utf8.prefix(len).enumerated() { raw[j] = CChar(byte) }
            }
        }
        var scene = MolEnvScene()
        scene.natoms = Int32(nat)
        scene.atoms = cAtoms
        if let cell {
            scene.cell = ((cell.a.x, cell.a.y, cell.a.z),
                          (cell.b.x, cell.b.y, cell.b.z),
                          (cell.c.x, cell.c.y, cell.c.z))
        } else {
            scene.cell = ((0, 0, 0), (0, 0, 0), (0, 0, 0))
        }
        scene.is_crystal = isCrystal ? 1 : 0
        scene.periodic_dim = Int32(periodicDim)

        var nb: Int32 = 0
        var bondPtr: UnsafeMutablePointer<MolEnvBond>? = nil
        // factor 1.0 — same as the parsers use
        bondPtr = molenv_make_bonds(&scene, 1.0, &nb)
        defer {
            if let bp = bondPtr { molenv_free_bonds(bp) }
            cAtoms.deallocate()
        }

        guard nb > 0, let bp = bondPtr else { return [] }
        let rawBonds = (0..<Int(nb)).map { index in
            let bond = bp[index]
            return Bond(i: Int(bond.i), j: Int(bond.j),
                        image: SIMD3<Int64>(bond.image.0, bond.image.1, bond.image.2))
        }
        // Keep the defensive coincidence filter for malformed/manual atom sets.
        // Normal supercell expansion uses the scaled bond cell above, so translated
        // copies are no longer mistaken for zero-distance primitive images.
        guard isCrystal, periodicDim >= 1, let cell else { return rawBonds }
        return rawBonds.filter { bond in
            guard bond.i >= 0, bond.i < atoms.count, bond.j >= 0, bond.j < atoms.count else { return false }
            guard let d = PeriodicGeometry.minimumImageDistance(
                from: atoms[bond.i].coord, to: atoms[bond.j].coord,
                cell: cell, periodicDim: periodicDim) else { return true }
            return d >= 0.05
        }
    }

    func applySlab(_ slab: Slab?) -> Scene {
        // No-op: clearing a slab that isn't applied. Avoids an O(n) rebond every
        // frame when the controller re-runs applySlab(nil) on an unslabbed scene.
        if slab == nil && self.slab == nil { return self }
        guard let slab else {
            // Removing the slab — restore the full pre-slab atom set.
            var s = self
            s.atoms = preslabAtoms.isEmpty ? s.atoms : preslabAtoms
            if let c = s.cell {
                let bondCell = Self.bondCell(c, superCell: s.superCell, periodicDim: s.periodicDim)
                s.bonds = Self.rebond(s.atoms, cell: bondCell,
                                      isCrystal: s.isCrystal, periodicDim: s.periodicDim)
            } else { s.bonds = [] }
            s.slab = nil
            // Restoring the pre-slab set invalidates indices into the filtered set;
            // leave selection untouched only when the set is genuinely unchanged.
            if s.atoms != atoms {
                s.selectedAtoms = []
                s.measurementResult = nil
            }
            return s
        }
        // A slab needs a unit cell to filter in; a molecule (no cell) can't be slabbed.
        // Refuse rather than fall into the remove-slab branch and wipe the bonds.
        guard let cell else { return self }
        let nA = SIMD3(Float(slab.planeA.h), Float(slab.planeA.k), Float(slab.planeA.l))
        let nB = SIMD3(Float(slab.planeB.h), Float(slab.planeB.k), Float(slab.planeB.l))
        let dA = slab.planeA.distance
        let dB = slab.planeB.distance
        // Filter from the pre-slab (widened) set so that changing the slab
        // distance does not compound on a previous slab result.
        let src = preslabAtoms.isEmpty ? atoms : preslabAtoms
        var kept: [Atom] = []
        for a in src {
            // A singular cell has no valid fractional coordinates — filtering
            // against a fabricated origin would silently distort the slab, so
            // refuse and leave the scene unchanged.
            guard let frac = cartesianToFractional(a.coord, cell: cell) else { return self }
            let projA = frac.x*nA.x + frac.y*nA.y + frac.z*nA.z
            let projB = frac.x*nB.x + frac.y*nB.y + frac.z*nB.z
            if projA >= dA && projB <= dB { kept.append(a) }
        }
        var out = self
        if out.preslabAtoms.isEmpty { out.preslabAtoms = src }
        out.atoms = kept
        let bondCell = Self.bondCell(cell, superCell: out.superCell, periodicDim: out.periodicDim)
        out.bonds = Self.rebond(kept, cell: bondCell, isCrystal: true, periodicDim: out.periodicDim)
        out.slab = slab
        // A filter that drops atoms invalidates selection indices; if the filtered
        // set is identical to the current one the indices are still valid.
        if kept != atoms {
            out.selectedAtoms = []
            out.measurementResult = nil
        }
        return out
    }

    /// Convert a Cartesian coordinate to fractional (crystal) coordinates for
    /// the given unit cell.  Returns nil if the cell is singular.
    func fractionalCoord(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        guard let cell else { return nil }
        return cartesianToFractional(p, cell: cell)
    }

    private func cartesianToFractional(_ p: SIMD3<Float>, cell: Cell) -> SIMD3<Float>? {
        // Cramer's rule on the 3x3 [a b c] system: p = frac.x*a + frac.y*b + frac.z*c.
        // Columns of the matrix are the cell vectors a, b, c.
        let det = cell.a.x*(cell.b.y*cell.c.z - cell.c.y*cell.b.z)
                - cell.b.x*(cell.a.y*cell.c.z - cell.c.y*cell.a.z)
                + cell.c.x*(cell.a.y*cell.b.z - cell.b.y*cell.a.z)
        // Singular (zero-volume) cell: fractional coords are undefined. Callers
        // (applySlab) must refuse rather than fabricate an origin.
        guard abs(det) >= 1e-6 else { return nil }
        // det([col b c]) — replace column a with col
        func det1(_ col: SIMD3<Float>) -> Float {
            return col.x*(cell.b.y*cell.c.z - cell.c.y*cell.b.z)
                 - cell.b.x*(col.y*cell.c.z - cell.c.y*col.z)
                 + cell.c.x*(col.y*cell.b.z - cell.b.y*col.z)
        }
        // det([a col c]) — replace column b with col
        func det2(_ col: SIMD3<Float>) -> Float {
            return cell.a.x*(col.y*cell.c.z - cell.c.y*col.z)
                 - col.x*(cell.a.y*cell.c.z - cell.c.y*cell.a.z)
                 + cell.c.x*(cell.a.y*col.z - col.y*cell.a.z)
        }
        // det([a b col]) — replace column c with col
        func det3(_ col: SIMD3<Float>) -> Float {
            return cell.a.x*(cell.b.y*col.z - col.y*cell.b.z)
                 - cell.b.x*(cell.a.y*col.z - col.y*cell.a.z)
                 + col.x*(cell.a.y*cell.b.z - cell.b.y*cell.a.z)
        }
        return SIMD3(det1(p)/det, det2(p)/det, det3(p)/det)
    }

    /// Overflow-safe, strictly positive Int triple product; nil if any factor is
    /// non-positive or the product overflows. Used to size supercell expansions
    /// without the raw n1*n2*n3 wrapping past the atom cap on overflow.
    private static func positiveProduct(_ a: Int, _ b: Int, _ c: Int) -> Int? {
        guard a > 0, b > 0, c > 0 else { return nil }
        let ab = a.multipliedReportingOverflow(by: b)
        guard !ab.overflow else { return nil }
        let abc = ab.partialValue.multipliedReportingOverflow(by: c)
        return abc.overflow ? nil : abc.partialValue
    }

    /// Copy every appearance/display/quality setting from `other` onto `self`
    /// (all sidebar-controllable fields that are independent of parsed geometry).
    /// Geometry (atoms/bonds/cell), selection, measurement, currentFrame, camera,
    /// k-path and hbondPairs are NOT touched.
    mutating func adoptAppearance(from other: Scene) {
        displayMode = other.displayMode
        atomScale = other.atomScale
        bondRadius = other.bondRadius
        showCellFrame = other.showCellFrame
        showAxes = other.showAxes
        showLabels = other.showLabels
        showBondDistances = other.showBondDistances
        showScaleIndicator = other.showScaleIndicator
        showBrillouinZone = other.showBrillouinZone
        showStructure = other.showStructure
        showIsoSurface = other.showIsoSurface
        isoLevel = other.isoLevel
        isoSurfaces = other.isoSurfaces
        clipPlane = other.clipPlane
        colorPlaneColormap = other.colorPlaneColormap
        colorPlaneContourEnabled = other.colorPlaneContourEnabled
        colorPlaneContourCount = other.colorPlaneContourCount
        volumeSlices = other.volumeSlices
        showFermiSurface = other.showFermiSurface
        showForces = other.showForces
        forceScale = other.forceScale
        showColorPlane = other.showColorPlane
        msaaSampleCount = other.msaaSampleCount
        opacity = other.opacity
        lineWidth = other.lineWidth
        depthCueingStrength = other.depthCueingStrength
        aoStrength = other.aoStrength
        shadowStrength = other.shadowStrength
        aoQuality = other.aoQuality
        shadowQuality = other.shadowQuality
        lighting = other.lighting
        lights = other.lights
        hbondSettings = other.hbondSettings
        molecularSurfaceSettings = other.molecularSurfaceSettings
        atomColorScheme = other.atomColorScheme
        elementOverrides = other.elementOverrides
        repetitionMode = other.repetitionMode
        cellRodsEnabled = other.cellRodsEnabled
        cellRodFactor = other.cellRodFactor
        unicolorBonds = other.unicolorBonds
        unicolorBondHex = other.unicolorBondHex
        tessellationFactor = other.tessellationFactor
        background = other.background
        backgroundBottom = other.backgroundBottom
        backgroundType = other.backgroundType
        backgroundImagePath = other.backgroundImagePath
        anaglyphMode = other.anaglyphMode
        showBandSurface = other.showBandSurface
    }
}
