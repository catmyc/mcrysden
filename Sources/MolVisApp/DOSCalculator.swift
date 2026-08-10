import Foundation
import simd

/// Controls reconstruction of a total DOS from a uniform band-energy mesh.
struct DOSCalculationOptions {
    /// Gaussian standard deviation in eV.
    var broadeningEV: Float = 0.10
    /// Energy-grid spacing in eV.
    var energyStepEV: Float = 0.02
    /// Number of DOS samples is bounded so a malformed or extremely wide band
    /// range cannot create an unbounded allocation.
    var maximumSamples: Int = 100_001

    init(broadeningEV: Float = 0.10, energyStepEV: Float = 0.02,
         maximumSamples: Int = 100_001) {
        self.broadeningEV = broadeningEV
        self.energyStepEV = energyStepEV
        self.maximumSamples = maximumSamples
    }
}

enum DOSCalculationError: Error, CustomStringConvertible {
    case notMesh
    case malformedBandStructure
    case missingWeights
    case missingCell(periodicDim: Int)
    case invalidCellMeasure
    case invalidOptions
    case energyGridTooLarge

    var description: String {
        switch self {
        case .notMesh:
            return "DOS requires a uniform k-point mesh, not a band path"
        case .malformedBandStructure:
            return "malformed band mesh"
        case .missingWeights:
            return "band mesh has no finite positive k-point weights"
        case .missingCell(let dim):
            return "periodicDim=" + String(dim) + " DOS requires real-space cell vectors"
        case .invalidCellMeasure:
            return "real-space cell has an invalid length, area, or volume"
        case .invalidOptions:
            return "DOS broadening and energy step must be finite and positive"
        case .energyGridTooLarge:
            return "DOS energy grid exceeds the configured sample limit"
        }
    }
}

/// Reconstructs a total DOS from QE band energies on a uniform k-point mesh.
///
/// The QE integration weights are retained exactly. This is important because
/// QE commonly prints weights summing to two for a non-spin-polarized run and
/// the integral of the resulting DOS must therefore count the corresponding
/// number of states per unit cell. Spin channels are summed as separate
/// eigenvalue channels; no additional degeneracy factor is guessed.
enum DOSCalculator {
    static func make(from bands: BandStructure,
                     options: DOSCalculationOptions = DOSCalculationOptions()) throws -> DensityOfStates {
        guard bands.isMesh else { throw DOSCalculationError.notMesh }
        guard bands.hasValidChannelLayout,
              bands.nBands > 0,
              bands.kPointsPerSpin > 0,
              bands.kPoints.count == bands.nSpin * bands.kPointsPerSpin else {
            throw DOSCalculationError.malformedBandStructure
        }
        guard options.broadeningEV.isFinite, options.broadeningEV > 0,
              options.energyStepEV.isFinite, options.energyStepEV > 0,
              options.maximumSamples >= 2 else {
            throw DOSCalculationError.invalidOptions
        }

        let values = bands.kPoints.flatMap { $0.energies.prefix(bands.nBands) }
        guard values.count == bands.nSpin * bands.kPointsPerSpin * bands.nBands,
              values.allSatisfy({ $0.isFinite }) else {
            throw DOSCalculationError.malformedBandStructure
        }

        let weights = bands.kPoints.map(\.weight)
        guard weights.count == bands.kPoints.count,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw DOSCalculationError.missingWeights
        }

        let minimum = values.min()!
        let maximum = values.max()!
        let padding = max(4 * options.broadeningEV, options.energyStepEV * 2)
        let lower = minimum - padding
        var upper = maximum + padding
        if !(lower.isFinite && upper.isFinite) || lower >= upper {
            throw DOSCalculationError.malformedBandStructure
        }

        let rawCount = Double(upper - lower) / Double(options.energyStepEV) + 1.0
        guard rawCount.isFinite, rawCount >= 2 else {
            throw DOSCalculationError.malformedBandStructure
        }
        // Check the floating-point count before converting to Int; a valid
        // Float range can still be far outside Int's representable range.
        guard rawCount <= Double(options.maximumSamples),
              rawCount < Double(Int.max) else {
            throw DOSCalculationError.energyGridTooLarge
        }
        let requestedCount = Int(ceil(rawCount))
        guard requestedCount >= 2 else { throw DOSCalculationError.malformedBandStructure }
        // Make the final endpoint exactly coincide with the requested grid so
        // the energy spacing remains deterministic across platforms.
        let count = requestedCount
        upper = lower + Float(count - 1) * options.energyStepEV
        let energies = (0..<count).map { lower + Float($0) * options.energyStepEV }

        let sigma = Double(options.broadeningEV)
        let inverseNormalization = 1.0 / (sigma * sqrt(2.0 * Double.pi))
        var dos = Array(repeating: 0.0, count: count)
        for channelPoint in bands.kPoints {
            let weight = Double(channelPoint.weight)
            for energy in channelPoint.energies.prefix(bands.nBands) {
                let center = Double(energy)
                for index in dos.indices {
                    let x = (Double(energies[index]) - center) / sigma
                    // Values beyond 8 sigma are numerically negligible and
                    // skipping them materially reduces cost for wide grids.
                    guard abs(x) <= 8 else { continue }
                    dos[index] += weight * inverseNormalization * exp(-0.5 * x * x)
                }
            }
        }

        let metadata = try metadata(for: bands)
        let scale = Double(metadata.cellMeasureAngstrom ?? 1)
        let normalized = dos.map { Float($0 / scale) }
        guard normalized.allSatisfy({ $0.isFinite }) else {
            throw DOSCalculationError.malformedBandStructure
        }
        return DensityOfStates(
            energies: energies,
            series: [DOSSeries(label: "Total DOS", values: normalized)],
            fermiEnergy: bands.fermiEnergy,
            metadata: metadata
        )
    }

    /// Public so parser and tests can validate the same dimensional geometry
    /// used by the DOS calculator.
    static func metadata(for bands: BandStructure) throws -> DOSMetadata {
        let dim = min(3, max(0, bands.periodicDim))
        guard dim > 0 else {
            return DOSMetadata(source: .bandMesh, periodicDim: 0, cellMeasureAngstrom: nil)
        }
        guard let cell = bands.cell else {
            throw DOSCalculationError.missingCell(periodicDim: dim)
        }

        let measure: Float
        switch dim {
        case 1:
            measure = length(cell.a)
        case 2:
            measure = length(cross(cell.a, cell.b))
        default:
            measure = abs(dot(cell.a, cross(cell.b, cell.c)))
        }
        guard measure.isFinite, measure > 1e-7 else {
            throw DOSCalculationError.invalidCellMeasure
        }
        return DOSMetadata(source: .bandMesh, periodicDim: dim,
                           cellMeasureAngstrom: measure)
    }
}
