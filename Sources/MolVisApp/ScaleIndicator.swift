import Foundation
import simd

/// A camera-relative, world-space scale marker.
///
/// The value is deliberately computed independently of the camera orbit.  The
/// camera is still validated at the API boundary so malformed persisted state
/// cannot make its way into the calculation.
internal struct ScaleIndicator: Equatable {
    let lengthAngstrom: Double
    let pixelWidth: CGFloat
    let text: String

    /// Makes a scale marker whose rendered width is as close as possible to
    /// `targetPixelWidth` among the usual 1/2/5 decade values.
    static func make(camera: Camera,
                     viewport: SIMD2<Float>,
                     targetPixelWidth: CGFloat = 110) -> ScaleIndicator? {
        guard let validatedCamera = try? Camera.validated(camera),
              viewport.x.isFinite, viewport.x > 0,
              viewport.y.isFinite, viewport.y > 0,
              targetPixelWidth.isFinite, targetPixelWidth > 0 else {
            return nil
        }

        let viewportHeight = Double(viewport.y)
        let distance = Double(validatedCamera.distance)
        let verticalSpan: Double

        if validatedCamera.perspective {
            // The scale is evaluated on the plane through the camera center,
            // at `distance` from the eye, using the same 45-degree FOV as the
            // camera projection matrix.
            verticalSpan = 2.0 * distance * tan(Double.pi / 8.0)
        } else {
            // This is the vertical extent used by Camera.projectionMatrix.
            verticalSpan = 2.0 * max(1.0, distance)
        }

        guard verticalSpan.isFinite, verticalSpan > 0 else { return nil }

        let pixelsPerAngstrom = viewportHeight / verticalSpan
        guard pixelsPerAngstrom.isFinite, pixelsPerAngstrom > 0 else { return nil }

        let target = Double(targetPixelWidth)
        guard target.isFinite, target > 0 else { return nil }

        // The desired world-space length is only used to locate the relevant
        // decade.  The final comparison is done in pixel space, which avoids
        // assuming that a rounded decimal candidate has the exact desired
        // world-space value.
        let idealLength = target / pixelsPerAngstrom
        guard idealLength.isFinite, idealLength > 0 else { return nil }

        let logarithm = log10(idealLength)
        guard logarithm.isFinite else { return nil }
        let flooredLogarithm = floor(logarithm)
        guard flooredLogarithm >= Double(Self.minimumCandidateExponent),
              flooredLogarithm <= Double(Self.maximumCandidateExponent) else {
            return nil
        }

        // The logarithm is known to be in a small, bounded range before this
        // conversion.  Three neighboring decades and three bases are enough
        // to cover every possible nearest 1/2/5 candidate, including a
        // round-off error at a decade boundary.
        let decade = Int(flooredLogarithm)
        var best: Candidate?
        var bestDifference = Double.greatestFiniteMagnitude

        for offset in -1...1 {
            let exponent = decade + offset
            guard exponent >= Self.minimumCandidateExponent,
                  exponent <= Self.maximumCandidateExponent else {
                continue
            }

            for base in [1, 2, 5] {
                guard let length = Self.decimalCandidate(base: base, exponent: exponent) else {
                    continue
                }

                let widthInDouble = length * pixelsPerAngstrom
                guard widthInDouble.isFinite, widthInDouble > 0 else { continue }

                let difference = abs(widthInDouble - target)
                guard difference.isFinite else { continue }

                // Candidates are visited in ascending order.  Keeping the
                // first candidate on an exact tie favors the shorter marker.
                if best == nil || difference < bestDifference {
                    best = Candidate(base: base, exponent: exponent, length: length,
                                     pixelWidth: widthInDouble)
                    bestDifference = difference
                }
            }
        }

        guard let candidate = best else { return nil }
        let pixelWidth = CGFloat(candidate.pixelWidth)
        guard pixelWidth.isFinite, pixelWidth > 0 else { return nil }

        return ScaleIndicator(lengthAngstrom: candidate.length,
                              pixelWidth: pixelWidth,
                              text: Self.text(for: candidate))
    }

    private struct Candidate {
        let base: Int
        let exponent: Int
        let length: Double
        let pixelWidth: Double
    }

    // These bounds cover every finite Double decade.  Candidate generation is
    // nevertheless fixed at nine attempts, rather than iterating over this
    // entire range.  At -324 only the rounded, positive subnormal candidates
    // can be represented; at +308 only bases whose product remains finite are
    // retained.
    private static let minimumCandidateExponent = -324
    private static let maximumCandidateExponent = 308

    private static func decimalCandidate(base: Int, exponent: Int) -> Double? {
        let power = pow(10.0, Double(exponent))
        if power.isFinite, power > 0 {
            let value = Double(base) * power
            guard value.isFinite, value > 0 else { return nil }
            return value
        }

        // `pow(10, -324)` rounds to zero, although 2×10^-324 and 5×10^-324
        // both round to Double's least positive subnormal.  Preserve those
        // representable positive candidates without ever multiplying through
        // an underflowed zero.
        guard exponent == minimumCandidateExponent, base > 1 else { return nil }
        return Double.leastNonzeroMagnitude
    }

    private static func text(for candidate: Candidate) -> String {
        let usesNanometers = candidate.length >= 10.0
        let displayExponent = usesNanometers ? candidate.exponent - 1 : candidate.exponent
        let unit = usesNanometers ? "nm" : "Å"
        return "\(decimalText(base: candidate.base, exponent: displayExponent)) \(unit)"
    }

    /// Formats the exact decimal construction of a candidate, rather than
    /// round-tripping its binary Double through a general-purpose formatter.
    /// This keeps labels such as `0.5 Å` free of binary floating-point noise.
    private static func decimalText(base: Int, exponent: Int) -> String {
        // Fixed notation is concise for the scales normally shown by a
        // viewport.  Scientific notation keeps pathological but representable
        // values compact and useful instead of allocating hundreds of zeros.
        if (-6...6).contains(exponent) {
            if exponent >= 0 {
                return "\(base)\(String(repeating: "0", count: exponent))"
            }
            return "0.\(String(repeating: "0", count: -exponent - 1))\(base)"
        }

        let sign = exponent >= 0 ? "+" : ""
        return "\(base)e\(sign)\(exponent)"
    }
}
