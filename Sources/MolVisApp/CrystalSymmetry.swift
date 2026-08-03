import Foundation
import simd
import MolEnvSpglib

enum CrystalSystem: String, Equatable {
    case triclinic
    case monoclinic
    case orthorhombic
    case tetragonal
    case trigonal
    case hexagonal
    case cubic
    case unknown

    var label: String {
        switch self {
        case .triclinic: return "Triclinic"
        case .monoclinic: return "Monoclinic"
        case .orthorhombic: return "Orthorhombic"
        case .tetragonal: return "Tetragonal"
        case .trigonal: return "Trigonal"
        case .hexagonal: return "Hexagonal"
        case .cubic: return "Cubic"
        case .unknown: return "Unknown"
        }
    }
}

enum CrystalCentering: String, Equatable {
    case primitive = "P"
    case baseA = "A"
    case baseB = "B"
    case baseC = "C"
    case body = "I"
    case face = "F"
    case rhombohedral = "R"
    case unknown = "?"

    var label: String {
        switch self {
        case .primitive: return "Primitive (P)"
        case .baseA: return "A-centered"
        case .baseB: return "B-centered"
        case .baseC: return "C-centered"
        case .body: return "Body-centered (I)"
        case .face: return "Face-centered (F)"
        case .rhombohedral: return "Rhombohedral (R)"
        case .unknown: return "Unknown centering"
        }
    }
}

struct CrystalBravaisLattice: Equatable {
    let system: CrystalSystem
    let centering: CrystalCentering

    var label: String {
        guard centering != .unknown, system != .unknown else { return "Unavailable" }
        return "\(centering.rawValue) \(system.label)"
    }
}

struct CrystalSymmetryMatrix: Equatable {
    /// Row-major 3x3 values. Lattice matrices use rows as basis vectors;
    /// transformation and rotation matrices use the ordinary matrix convention.
    let values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    static let identity = CrystalSymmetryMatrix([
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ])

    subscript(row: Int, column: Int) -> Double {
        values[row * 3 + column]
    }

    var transposed: CrystalSymmetryMatrix {
        CrystalSymmetryMatrix((0..<3).flatMap { row in
            (0..<3).map { column in self[column, row] }
        })
    }

    var determinant: Double {
        guard values.count == 9 else { return .nan }
        return self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
             - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
             + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
    }

    var isFinite3x3: Bool {
        values.count == 9 && values.allSatisfy(\.isFinite)
    }

    func inverted() -> CrystalSymmetryMatrix? {
        guard values.count == 9 else { return nil }
        let scale = values.map(abs).max() ?? 0
        guard scale.isFinite, scale > 0 else { return nil }
        let normalized = CrystalSymmetryMatrix(values.map { $0 / scale })
        let det = normalized.determinant
        guard det.isFinite, abs(det) > 1e-14 else { return nil }
        let a = normalized[0, 0], b = normalized[0, 1], c = normalized[0, 2]
        let d = normalized[1, 0], e = normalized[1, 1], f = normalized[1, 2]
        let g = normalized[2, 0], h = normalized[2, 1], i = normalized[2, 2]
        let inverseScale = 1 / scale
        return CrystalSymmetryMatrix([
            (e * i - f * h) / det * inverseScale, (c * h - b * i) / det * inverseScale,
            (b * f - c * e) / det * inverseScale,
            (f * g - d * i) / det * inverseScale, (a * i - c * g) / det * inverseScale,
            (c * d - a * f) / det * inverseScale,
            (d * h - e * g) / det * inverseScale, (b * g - a * h) / det * inverseScale,
            (a * e - b * d) / det * inverseScale,
        ])
    }

    func multiplied(by rhs: CrystalSymmetryMatrix) -> CrystalSymmetryMatrix {
        CrystalSymmetryMatrix((0..<3).flatMap { row in
            (0..<3).map { column in
                (0..<3).reduce(0.0) { $0 + self[row, $1] * rhs[$1, column] }
            }
        })
    }

    func applying(to vector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            self[0, 0] * vector.x + self[0, 1] * vector.y + self[0, 2] * vector.z,
            self[1, 0] * vector.x + self[1, 1] * vector.y + self[1, 2] * vector.z,
            self[2, 0] * vector.x + self[2, 1] * vector.y + self[2, 2] * vector.z
        )
    }
}

struct CrystalSymmetryOperation: Equatable {
    let rotation: [Int]
    let translation: SIMD3<Double>
}

struct CrystalStandardizedStructure: Equatable {
    /// Each row is one direct basis vector (a, b, c), in Angstroms.
    let latticeRows: CrystalSymmetryMatrix
    let fractionalPositions: [SIMD3<Double>]
    let atomicTypes: [Int]
    let mappingToPrimitive: [Int]?

    var atomCount: Int { fractionalPositions.count }
    var volume: Double { abs(latticeRows.determinant) }
}

struct CrystalSymmetry {
    let spaceGroupNumber: Int
    let internationalSymbol: String
    let hallNumber: Int?
    let hallSymbol: String?
    let settingChoice: String?
    let pointGroupSymbol: String
    let crystalSystem: CrystalSystem
    let bravaisLattice: CrystalBravaisLattice

    let wyckoffLetters: [String]
    let siteSymmetrySymbols: [String]
    let equivalentAtoms: [Int]
    let crystallographicOrbits: [Int]
    let inputToPrimitiveMapping: [Int]
    let symmetryOperations: [CrystalSymmetryOperation]

    let primitiveStructure: CrystalStandardizedStructure
    let conventionalStructure: CrystalStandardizedStructure

    /// Input lattice, the pre-idealized Bravais lattice, and the returned
    /// idealized conventional lattice all use row-major direct basis vectors.
    let inputLattice: CrystalSymmetryMatrix
    let preidealizedBravaisLattice: CrystalSymmetryMatrix
    let detectedPrimitiveLattice: CrystalSymmetryMatrix
    let standardizedLattice: CrystalSymmetryMatrix
    /// Raw Cartesian rotation from the pre-idealized Bravais frame to the
    /// idealized standardized frame. It is not a fractional-coordinate map.
    let standardizedRotationMatrix: CrystalSymmetryMatrix

    /// Spglib's P: input fractional -> pre-idealized Bravais fractional.
    /// For positions, the complete affine map also adds `originShift`.
    let inputToPreidealizedBravaisFractional: CrystalSymmetryMatrix
    /// k_input = P^T * k_preidealizedBravais.
    let preidealizedBravaisReciprocalToInput: CrystalSymmetryMatrix
    /// Inverse directions are exposed explicitly for callers that need them.
    let preidealizedBravaisToInputFractional: CrystalSymmetryMatrix
    let inputReciprocalToPreidealizedBravais: CrystalSymmetryMatrix
    let originShift: SIMD3<Double>

    /// Maps primitive fractional coordinates to conventional fractional
    /// coordinates: x_conventional = primitiveToConventionalFractional * x_primitive.
    /// Computed as (L_primitive * L_conventional^-1)^T where L matrices use
    /// rows as basis vectors. The reciprocal directions are the inverse transposes.
    let primitiveToConventionalFractional: CrystalSymmetryMatrix
    let conventionalToPrimitiveFractional: CrystalSymmetryMatrix
    let primitiveReciprocalToConventional: CrystalSymmetryMatrix
    let conventionalReciprocalToPrimitive: CrystalSymmetryMatrix
    let tolerance: Double
}

enum CrystalSymmetryUnavailableReason: Equatable, CustomStringConvertible {
    case notThreeDimensional
    case missingCell
    case noAtoms
    case atomCountExceeded(Int, Int)
    case nonFiniteCell
    case singularCell
    case nonFiniteAtom(Int)
    case invalidAtomicNumber(Int)
    case invalidTolerance
    case incompleteInput(SymmetryInputCompleteness)
    case bridgeFailure(String)

    var isAsymmetricUnitInput: Bool {
        if case .incompleteInput(.asymmetricUnit) = self { return true }
        return false
    }
    var isIncompleteInput: Bool {
        if case .incompleteInput = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .notThreeDimensional: return "requires a 3D periodic crystal"
        case .missingCell: return "no unit cell"
        case .noAtoms: return "no base atoms"
        case .atomCountExceeded(let count, let cap): return "base atom count \(count) exceeds cap \(cap)"
        case .nonFiniteCell: return "unit cell contains a non-finite value"
        case .singularCell: return "unit cell is singular or numerically degenerate"
        case .nonFiniteAtom(let index): return "atom \(index + 1) contains a non-finite coordinate"
        case .invalidAtomicNumber(let index): return "atom \(index + 1) has an invalid atomic number"
        case .invalidTolerance: return "symmetry tolerance must be in the practical range [1e-8, 1e-1] Angstrom"
        case .incompleteInput(let completeness): return completeness.symmetryUnavailableReason
        case .bridgeFailure(let message): return message
        }
    }
}

struct CrystalSymmetryAnalysis {
    let symmetry: CrystalSymmetry?
    let unavailableReason: CrystalSymmetryUnavailableReason?
    let tolerance: Double
    /// The input-completeness assumption supplied to the analyzer. Preserved
    /// across coordinate edits so an asymmetric-unit/unknown file is never
    /// falsely promoted to `.complete` by a later edit.
    let inputCompleteness: SymmetryInputCompleteness

    var isAvailable: Bool { symmetry != nil }
    var reasonDescription: String? { unavailableReason?.description }

    init(symmetry: CrystalSymmetry?, unavailableReason: CrystalSymmetryUnavailableReason?,
         tolerance: Double, inputCompleteness: SymmetryInputCompleteness = .complete) {
        self.symmetry = symmetry
        self.unavailableReason = unavailableReason
        self.tolerance = tolerance
        self.inputCompleteness = inputCompleteness
    }
}

/// Keep the derived value out of persisted Scene data. StateStore's explicit
/// flat payload and the targeted synthesized-Codable overloads omit it; loaded
/// structures recompute it synchronously during Scene initialization.
@propertyWrapper
struct NonPersisted<Value>: Codable {
    var wrappedValue: Value?

    init() { wrappedValue = nil }
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// The derived analysis is a runtime cache, not a Scene document field. These
// overloads are selected by synthesized Scene Codable code: encoding omits the
// key, while decoding accepts both old documents with no key and transient
// documents produced by older builds that wrote null.
extension KeyedEncodingContainer {
    func encode(_ value: NonPersisted<CrystalSymmetryAnalysis>, forKey key: Key) throws {
        // Intentionally omitted.
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: NonPersisted<CrystalSymmetryAnalysis>.Type,
                forKey key: Key) throws -> NonPersisted<CrystalSymmetryAnalysis> {
        NonPersisted()
    }
}

enum CrystalSymmetryAnalyzer {
    static let defaultTolerance = 1e-5
    /// Symmetry analysis is synchronous with Scene loading. Keep the cap small
    /// enough that a malformed or unexpectedly widened input cannot stall the UI.
    static let baseAtomCap = 4096
    /// Spglib's symprec is a Cartesian distance in Angstroms. This practical
    /// range rejects pathological values without retrying or changing the
    /// caller's requested tolerance.
    static let practicalToleranceRange = 1e-8...1e-1

    static func analyze(cell: Cell?, atoms: [Atom], isCrystal: Bool,
                        periodicDim: Int, tolerance: Double = defaultTolerance,
                        inputCompleteness: SymmetryInputCompleteness = .complete) -> CrystalSymmetryAnalysis {
        // Helper that threads `inputCompleteness` into every return path so the
        // analyzer never silently drops the caller's completeness assumption.
        func result(symmetry: CrystalSymmetry?,
                    reason: CrystalSymmetryUnavailableReason?) -> CrystalSymmetryAnalysis {
            CrystalSymmetryAnalysis(symmetry: symmetry, unavailableReason: reason,
                                    tolerance: tolerance, inputCompleteness: inputCompleteness)
        }
        guard practicalToleranceRange.contains(tolerance) else {
            return result(symmetry: nil, reason: .invalidTolerance)
        }
        guard isCrystal, periodicDim == 3 else {
            return result(symmetry: nil, reason: .notThreeDimensional)
        }
        guard inputCompleteness == .complete else {
            return result(symmetry: nil, reason: .incompleteInput(inputCompleteness))
        }
        guard let cell else {
            return result(symmetry: nil, reason: .missingCell)
        }
        guard !atoms.isEmpty else {
            return result(symmetry: nil, reason: .noAtoms)
        }
        guard atoms.count <= baseAtomCap else {
            return result(symmetry: nil, reason: .atomCountExceeded(atoms.count, baseAtomCap))
        }
        let cellValues = [cell.a.x, cell.a.y, cell.a.z,
                          cell.b.x, cell.b.y, cell.b.z,
                          cell.c.x, cell.c.y, cell.c.z].map(Double.init)
        guard cellValues.allSatisfy(\.isFinite) else {
            return result(symmetry: nil, reason: .nonFiniteCell)
        }
        let lattice = CrystalSymmetryMatrix(cellValues)
        guard isWellConditioned(lattice) else {
            return result(symmetry: nil, reason: .singularCell)
        }

        var fractional: [SIMD3<Double>] = []
        fractional.reserveCapacity(atoms.count)
        var types: [Int32] = []
        types.reserveCapacity(atoms.count)
        for (index, atom) in atoms.enumerated() {
            let cartesian = SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite else {
                return result(symmetry: nil, reason: .nonFiniteAtom(index))
            }
            guard atom.atomicNumber > 0, atom.atomicNumber <= Int(Int32.max) else {
                return result(symmetry: nil, reason: .invalidAtomicNumber(index))
            }
            guard let f = fractionalCoordinate(cartesian, latticeRows: lattice),
                  f.x.isFinite, f.y.isFinite, f.z.isFinite else {
                return result(symmetry: nil, reason: .singularCell)
            }
            fractional.append(f)
            types.append(Int32(atom.atomicNumber))
        }

        do {
            let symmetry = try CrystalSymmetryBridge.analyze(
                latticeRows: cellValues,
                fractionalPositions: fractional,
                types: types,
                tolerance: tolerance
            )
            return result(symmetry: symmetry, reason: nil)
        } catch {
            return result(symmetry: nil, reason: .bridgeFailure(error.localizedDescription))
        }
    }

    private static func fractionalCoordinate(_ point: SIMD3<Double>, latticeRows: CrystalSymmetryMatrix)
        -> SIMD3<Double>? {
        // The app's a, b, c are columns of the direct Cartesian basis. The
        // row-vector storage above is transposed here for Cramer's rule.
        let a = SIMD3(latticeRows[0, 0], latticeRows[0, 1], latticeRows[0, 2])
        let b = SIMD3(latticeRows[1, 0], latticeRows[1, 1], latticeRows[1, 2])
        let c = SIMD3(latticeRows[2, 0], latticeRows[2, 1], latticeRows[2, 2])
        let scale = latticeRows.values.map(abs).max() ?? 0
        guard scale.isFinite, scale > 0 else { return nil }
        let an = a / scale, bn = b / scale, cn = c / scale, pn = point / scale
        let determinant = simd_dot(an, simd_cross(bn, cn))
        guard determinant.isFinite, abs(determinant) > 1e-14 else { return nil }
        let x = simd_dot(pn, simd_cross(bn, cn)) / determinant
        let y = simd_dot(an, simd_cross(pn, cn)) / determinant
        let z = simd_dot(an, simd_cross(bn, pn)) / determinant
        return SIMD3(x, y, z)
    }

    private static func isWellConditioned(_ lattice: CrystalSymmetryMatrix) -> Bool {
        let scale = lattice.values.map(abs).max() ?? 0
        guard scale.isFinite, scale > 0 else { return false }
        let normalized = CrystalSymmetryMatrix(lattice.values.map { $0 / scale })
        let determinant = normalized.determinant
        return determinant.isFinite && abs(determinant) > 1e-12
    }
}

private enum CrystalSymmetryBridge {
    enum BridgeError: Error, LocalizedError {
        case status(String)
        case malformedResult

        var errorDescription: String? {
            switch self {
            case .status(let message): return message
            case .malformedResult: return "symmetry bridge returned malformed data"
            }
        }
    }

    static func analyze(latticeRows: [Double], fractionalPositions: [SIMD3<Double>],
                        types: [Int32], tolerance: Double) throws -> CrystalSymmetry {
        var flatPositions: [Double] = []
        flatPositions.reserveCapacity(fractionalPositions.count * 3)
        for position in fractionalPositions {
            flatPositions += [position.x, position.y, position.z]
        }
        var resultPointer: UnsafeMutablePointer<MolEnvSpglibResult>?
        let status = latticeRows.withUnsafeBufferPointer { latticeBuffer in
            flatPositions.withUnsafeBufferPointer { positionBuffer in
                types.withUnsafeBufferPointer { typeBuffer in
                    molenv_spglib_analyze(latticeBuffer.baseAddress,
                                           positionBuffer.baseAddress,
                                           typeBuffer.baseAddress,
                                           Int32(types.count), tolerance,
                                           &resultPointer)
                }
            }
        }
        guard status == MOLENV_SPGLIB_OK, let resultPointer else {
            let message: String
            if let errorPointer = molenv_spglib_last_error() {
                message = String(cString: errorPointer)
            } else {
                message = "symmetry bridge failed (status \(status))"
            }
            throw BridgeError.status(message.isEmpty ? "symmetry bridge failed" : message)
        }
        defer { molenv_spglib_result_free(resultPointer) }
        return try copyResult(resultPointer.pointee, atomCount: types.count, tolerance: tolerance)
    }

    private static func copyResult(_ result: MolEnvSpglibResult, atomCount: Int,
                                   tolerance: Double) throws -> CrystalSymmetry {
        let operationCount = Int(result.n_operations)
        let resultAtomCount = Int(result.n_atoms)
        let primitiveCount = Int(result.n_primitive_atoms)
        let conventionalCount = Int(result.n_std_atoms)
        guard operationCount >= 0, resultAtomCount == atomCount,
              primitiveCount > 0, conventionalCount > 0,
              resultAtomCount > 0, primitiveCount <= resultAtomCount,
              operationCount <= 4096, conventionalCount <= 400000 else {
            throw BridgeError.malformedResult
        }

        let wyckoffs = copyInts(result.wyckoffs, count: resultAtomCount)
        let equivalents = copyInts(result.equivalent_atoms, count: resultAtomCount)
        let orbits = copyInts(result.crystallographic_orbits, count: resultAtomCount)
        let mapping = copyInts(result.mapping_to_primitive, count: resultAtomCount)
        let stdTypes = copyInts(result.std_types, count: conventionalCount)
        let primitiveTypes = copyInts(result.primitive_types, count: primitiveCount)
        let stdMapping = copyInts(result.std_mapping_to_primitive, count: conventionalCount)
        guard wyckoffs.count == resultAtomCount, equivalents.count == resultAtomCount,
              orbits.count == resultAtomCount, mapping.count == resultAtomCount,
              stdTypes.count == conventionalCount, primitiveTypes.count == primitiveCount,
              stdMapping.count == conventionalCount else { throw BridgeError.malformedResult }
        guard mapping.allSatisfy({ $0 >= 0 && $0 < primitiveCount }),
              Set(mapping).count == primitiveCount else { throw BridgeError.malformedResult }

        let primitivePositions = copyPositions(result.primitive_positions, count: primitiveCount)
        let standardPositions = copyPositions(result.std_positions, count: conventionalCount)
        guard primitivePositions.count == primitiveCount, standardPositions.count == conventionalCount else {
            throw BridgeError.malformedResult
        }

        let operations = copyOperations(result.rotations, result.translations, count: operationCount)
        guard operations.count == operationCount else { throw BridgeError.malformedResult }
        let wyckoffLetters = wyckoffs.map { index in
            guard index >= 0, index < 26 else { return "?" }
            return String(UnicodeScalar(97 + index)!)
        }
        let siteSymbols = copySiteSymbols(result.site_symmetry_symbols, count: resultAtomCount)
        let inputLattice = CrystalSymmetryMatrix(copy9(result.input_lattice))
        let preidealizedBravaisLattice = CrystalSymmetryMatrix(copy9(result.preidealized_bravais_lattice))
        let detectedPrimitiveLattice = CrystalSymmetryMatrix(copy9(result.detected_primitive_lattice))
        let standardizedLattice = CrystalSymmetryMatrix(copy9(result.standardized_lattice))
        let transformation = CrystalSymmetryMatrix(copy9(result.transformation_matrix))
        let standardizedRotation = CrystalSymmetryMatrix(copy9(result.standardized_rotation_matrix))
        guard inputLattice.isFinite3x3, preidealizedBravaisLattice.isFinite3x3,
              detectedPrimitiveLattice.isFinite3x3, standardizedLattice.isFinite3x3,
              transformation.isFinite3x3, standardizedRotation.isFinite3x3,
              transformation.inverted() != nil,
              detectedPrimitiveLattice.inverted() != nil,
              standardizedLattice.inverted() != nil else {
            throw BridgeError.malformedResult
        }
        let conventional = CrystalStandardizedStructure(
            latticeRows: standardizedLattice,
            fractionalPositions: standardPositions,
            atomicTypes: stdTypes,
            mappingToPrimitive: stdMapping
        )
        let primitive = CrystalStandardizedStructure(
            latticeRows: detectedPrimitiveLattice,
            fractionalPositions: primitivePositions,
            atomicTypes: primitiveTypes,
            mappingToPrimitive: nil
        )
        guard let preidealizedToInput = transformation.inverted(),
              let standardizedInverse = conventional.latticeRows.inverted() else {
            throw BridgeError.malformedResult
        }
        let primitiveToConventional = primitive.latticeRows
            .multiplied(by: standardizedInverse)
            .transposed
        guard let conventionalToPrimitive = primitiveToConventional.inverted() else {
            throw BridgeError.malformedResult
        }
        let primitiveReciprocalToConventional = conventionalToPrimitive.transposed
        let conventionalReciprocalToPrimitive = primitiveToConventional.transposed
        let pointGroup = copyString(result.pointgroup_symbol)
        let international = copyString(result.international_symbol)
        let crystalSystem = system(for: Int(result.spacegroup_number))
        let centering = centering(for: international)
        return CrystalSymmetry(
            spaceGroupNumber: Int(result.spacegroup_number),
            internationalSymbol: international,
            hallNumber: result.hall_number > 0 ? Int(result.hall_number) : nil,
            hallSymbol: optionalString(result.hall_symbol),
            settingChoice: optionalString(result.choice),
            pointGroupSymbol: pointGroup,
            crystalSystem: crystalSystem,
            bravaisLattice: CrystalBravaisLattice(system: crystalSystem, centering: centering),
            wyckoffLetters: wyckoffLetters,
            siteSymmetrySymbols: siteSymbols,
            equivalentAtoms: equivalents,
            crystallographicOrbits: orbits,
            inputToPrimitiveMapping: mapping,
            symmetryOperations: operations,
            primitiveStructure: primitive,
            conventionalStructure: conventional,
            inputLattice: inputLattice,
            preidealizedBravaisLattice: preidealizedBravaisLattice,
            detectedPrimitiveLattice: detectedPrimitiveLattice,
            standardizedLattice: standardizedLattice,
            standardizedRotationMatrix: standardizedRotation,
            inputToPreidealizedBravaisFractional: transformation,
            preidealizedBravaisReciprocalToInput: transformation.transposed,
            preidealizedBravaisToInputFractional: preidealizedToInput,
            inputReciprocalToPreidealizedBravais: preidealizedToInput.transposed,
            originShift: SIMD3(copy3(result.origin_shift)),
            primitiveToConventionalFractional: primitiveToConventional,
            conventionalToPrimitiveFractional: conventionalToPrimitive,
            primitiveReciprocalToConventional: primitiveReciprocalToConventional,
            conventionalReciprocalToPrimitive: conventionalReciprocalToPrimitive,
            tolerance: tolerance
        )
    }

    private static func copyString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    private static func optionalString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        let value = copyString(pointer)
        return value.isEmpty ? nil : value
    }

    private static func copyInts(_ pointer: UnsafeMutablePointer<Int32>?, count: Int) -> [Int] {
        guard count > 0, let pointer else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count)).map(Int.init)
    }

    private static func copyPositions(_ pointer: UnsafeMutablePointer<Double>?, count: Int) -> [SIMD3<Double>] {
        guard count > 0, let pointer else { return [] }
        let values = UnsafeBufferPointer(start: pointer, count: count * 3)
        return (0..<count).map { SIMD3(values[$0 * 3], values[$0 * 3 + 1], values[$0 * 3 + 2]) }
    }

    private static func copyOperations(_ rotations: UnsafeMutablePointer<Int32>?,
                                       _ translations: UnsafeMutablePointer<Double>?,
                                       count: Int) -> [CrystalSymmetryOperation] {
        guard count > 0, let rotations, let translations else { return [] }
        let rotationValues = UnsafeBufferPointer(start: rotations, count: count * 9)
        let translationValues = UnsafeBufferPointer(start: translations, count: count * 3)
        return (0..<count).map { index in
            CrystalSymmetryOperation(
                rotation: (0..<9).map { Int(rotationValues[index * 9 + $0]) },
                translation: SIMD3(translationValues[index * 3],
                                   translationValues[index * 3 + 1],
                                   translationValues[index * 3 + 2])
            )
        }
    }

    private static func copySiteSymbols(_ pointer: UnsafeMutablePointer<CChar>?, count: Int) -> [String] {
        guard count > 0, let pointer else { return [] }
        return (0..<count).map { index in
            let record = UnsafeRawPointer(pointer.advanced(by: index * 7))
                .assumingMemoryBound(to: UInt8.self)
            let bytes = UnsafeBufferPointer(start: record, count: 7)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<length], as: UTF8.self)
        }
    }

    private static func copy3(_ tuple: (Double, Double, Double)) -> [Double] {
        [tuple.0, tuple.1, tuple.2]
    }

    private static func copy9(_ tuple: (Double, Double, Double, Double, Double, Double,
                                         Double, Double, Double)) -> [Double] {
        [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7, tuple.8]
    }

    private static func system(for number: Int) -> CrystalSystem {
        switch number {
        case 1...2: return .triclinic
        case 3...15: return .monoclinic
        case 16...74: return .orthorhombic
        case 75...142: return .tetragonal
        case 143...167: return .trigonal
        case 168...194: return .hexagonal
        case 195...230: return .cubic
        default: return .unknown
        }
    }

    private static func centering(for symbol: String) -> CrystalCentering {
        guard let first = symbol.first else { return .unknown }
        switch first {
        case "P": return .primitive
        case "A": return .baseA
        case "B": return .baseB
        case "C": return .baseC
        case "I": return .body
        case "F": return .face
        case "R": return .rhombohedral
        default: return .unknown
        }
    }
}
