import Foundation
import simd
import MolEnvSpglib

// HPKOT/SeekPath 2.1.0 band-structure k-path algorithm.
//
// Reference: Y. Hinuma, G. Pizzi, Y. Kumagai, F. Oba, I. Tanaka,
// "Band structure diagram paths based on crystallography",
// Computational Materials Science 128 (2017) 140-148.
//
// This implements the SeekPath 2.1.0 (hpkot recipe) algorithm: given the
// symmetry analysis (space group + standardized conventional cell), it selects
// the extended Bravais variant, evaluates the metric-dependent k-parameters,
// computes the special k-point coordinates in the PRIMITIVE reciprocal
// fractional basis, and exposes the ordered edge list with break indices.
//
// All path definitions (k-parameters, points, edges) are transcribed from the
// SeekPath 2.1.0 band_path_data directory. The variant-selection logic follows
// seekpath/hpkot/__init__.py.
//
// Source: SeekPath 2.1.0 (MIT license), https://github.com/giovannipizzi/seekpath
// Data:    seekpath/hpkot/band_path_data/{variant}/
// Logic:   seekpath/hpkot/__init__.py, tools.py, spg_mapping.py

// MARK: - SeekPath data model

/// A single k-parameter definition: a name and an expression evaluated from the
/// conventional cell parameters (a, b, c, cosα, cosβ, cosγ) and earlier k-params.
private struct KParamDef {
    let name: String
    let expression: String
}

/// Special k-point definition: a label and three coordinate expressions.
/// Each expression is either a literal ("0", "1/2", "1/4", ...) or references
/// a k-parameter (possibly with "1-", "-", "1/2-", "1/2+" prefixes).
private struct PointDef {
    let label: String
    let coordExprs: (String, String, String)
}

/// Complete path data for one extended Bravais variant.
private struct VariantPathData {
    let kParams: [KParamDef]
    let points: [PointDef]
    /// Ordered edge list: each edge is (startLabel, endLabel). Adjacent edges
    /// sharing an endpoint form a connected segment; a gap between non-adjacent
    /// edges is a break.
    let edges: [(String, String)]
}

// MARK: - K-parameter expression evaluation

/// Evaluate a k-parameter expression given the conventional cell parameters.
/// Mirrors seekpath/hpkot/tools.py eval_expr + eval_expr_simple + extend_kparam.
/// K-parameter expression evaluator. Mirrors seekpath/hpkot/tools.py
/// eval_expr + eval_expr_simple + extend_kparam. All methods return nil for
/// unknown expressions or missing parameters so malformed data does not trap.
enum KParamEval {

    /// Extend a k-parameter dictionary with derived expressions (1-x, -x, etc.).
    static func extend(_ kparam: [String: Double]) -> [String: Double] {
        var extended = kparam
        for (key, val) in kparam {
            extended["\(key)"] = val
            extended["-\(key)"] = -val
            extended["1-\(key)"] = 1.0 - val
            extended["-1+\(key)"] = -1.0 + val
            extended["1/2-\(key)"] = 0.5 - val
            extended["1/2+\(key)"] = 0.5 + val
        }
        return extended
    }

    /// Evaluate a simple expression: a literal rational or a k-parameter reference.
    /// Returns nil for unknown expressions so malformed data does not trap.
    static func evalSimple(_ expr: String, _ kparam: [String: Double]) -> Double? {
        switch expr {
        case "0": return 0.0
        case "1/2": return 0.5
        case "1": return 1.0
        case "-1/2": return -0.5
        case "1/4": return 0.25
        case "3/8": return 3.0 / 8.0
        case "3/4": return 0.75
        case "5/8": return 5.0 / 8.0
        case "1/3": return 1.0 / 3.0
        default:
            if let v = kparam[expr] { return v }
            // Try to parse as a Double literal
            if let d = Double(expr) { return d }
            return nil
        }
    }

    /// Evaluate a compound expression involving cell parameters.
    /// Returns nil for unknown expressions or missing k-parameters so malformed
    /// data does not trap.
    static func evalCompound(_ expr: String, _ a: Double, _ b: Double, _ c: Double,
                             _ cosalpha: Double, _ cosbeta: Double, _ cosgamma: Double,
                             _ kparam: [String: Double]) -> Double? {
        let sinbeta = sqrt(1.0 - cosbeta * cosbeta)

        switch expr {
        case "(a*a/b/b+(1+a/c*cosbeta)/sinbeta/sinbeta)/4":
            return (a * a / b / b + (1.0 + a / c * cosbeta) / sinbeta / sinbeta) / 4.0
        case "1-Z*b*b/a/a":
            guard let Z = kparam["Z"] else { return nil }
            return 1.0 - Z * b * b / a / a
        case "1/2-2*Z*c*cosbeta/a":
            guard let Z = kparam["Z"] else { return nil }
            return 0.5 - 2.0 * Z * c * cosbeta / a
        case "E/2+a*a/4/b/b+a*c*cosbeta/2/b/b":
            guard let E = kparam["E"] else { return nil }
            return E / 2.0 + a * a / 4.0 / b / b + a * c * cosbeta / 2.0 / b / b
        case "2*F-Z":
            guard let F = kparam["F"], let Z = kparam["Z"] else { return nil }
            return 2.0 * F - Z
        case "c/2/a/cosbeta*(1-4*U+a*a*sinbeta*sinbeta/b/b)":
            guard let U = kparam["U"] else { return nil }
            return c / 2.0 / a / cosbeta * (1.0 - 4.0 * U + a * a * sinbeta * sinbeta / b / b)
        case "-1/4+W/2-Z*c*cosbeta/a":
            guard let W = kparam["W"], let Z = kparam["Z"] else { return nil }
            return -0.25 + W / 2.0 - Z * c * cosbeta / a
        case "(2+a/c*cosbeta)/4/sinbeta/sinbeta":
            return (2.0 + a / c * cosbeta) / 4.0 / sinbeta / sinbeta
        case "3/4-b*b/4/a/a/sinbeta/sinbeta":
            return 0.75 - b * b / 4.0 / a / a / sinbeta / sinbeta
        case "S-(3/4-S)*a*cosbeta/c":
            guard let S = kparam["S"] else { return nil }
            return S - (0.75 - S) * a * cosbeta / c
        case "(1+a*a/b/b)/4":
            return (1.0 + a * a / b / b) / 4.0
        case "-a*c*cosbeta/2/b/b":
            return -a * c * cosbeta / 2.0 / b / b
        case "1+Z-2*M":
            guard let Z = kparam["Z"], let M = kparam["M"] else { return nil }
            return 1.0 + Z - 2.0 * M
        case "X-2*D":
            guard let X = kparam["X"], let D = kparam["D"] else { return nil }
            return X - 2 * D
        case "(1+a/c*cosbeta)/2/sinbeta/sinbeta":
            return (1.0 + a / c * cosbeta) / 2.0 / sinbeta / sinbeta
        case "1/2+Y*c*cosbeta/a":
            guard let Y = kparam["Y"] else { return nil }
            return 0.5 + Y * c * cosbeta / a
        case "a*a/4/c/c":
            return a * a / 4.0 / c / c
        case "5/6-2*D":
            guard let D = kparam["D"] else { return nil }
            return 5.0 / 6.0 - 2.0 * D
        case "1/3+D":
            guard let D = kparam["D"] else { return nil }
            return 1.0 / 3.0 + D
        case "1/6-c*c/9/a/a":
            return 1.0 / 6.0 - c * c / 9.0 / a / a
        case "1/2-2*Z":
            guard let Z = kparam["Z"] else { return nil }
            return 0.5 - 2.0 * Z
        case "1/2+Z":
            guard let Z = kparam["Z"] else { return nil }
            return 0.5 + Z
        case "(1+b*b/c/c)/4":
            return (1.0 + b * b / c / c) / 4.0
        case "(1+c*c/b/b)/4":
            return (1.0 + c * c / b / b) / 4.0
        case "(1+b*b/a/a)/4":
            return (1.0 + b * b / a / a) / 4.0
        case "(1+a*a/b/b-a*a/c/c)/4":
            return (1.0 + a * a / b / b - a * a / c / c) / 4.0
        case "(1+a*a/b/b+a*a/c/c)/4":
            return (1.0 + a * a / b / b + a * a / c / c) / 4.0
        case "(1+c*c/a/a-c*c/b/b)/4":
            return (1.0 + c * c / a / a - c * c / b / b) / 4.0
        case "(1+c*c/a/a+c*c/b/b)/4":
            return (1.0 + c * c / a / a + c * c / b / b) / 4.0
        case "(1+b*b/a/a-b*b/c/c)/4":
            return (1.0 + b * b / a / a - b * b / c / c) / 4.0
        case "(1+c*c/b/b-c*c/a/a)/4":
            return (1.0 + c * c / b / b - c * c / a / a) / 4.0
        case "(1+a*a/c/c)/4":
            return (1.0 + a * a / c / c) / 4.0
        case "(b*b-a*a)/4/c/c":
            return (b * b - a * a) / 4.0 / c / c
        case "(a*a+b*b)/4/c/c":
            return (a * a + b * b) / 4.0 / c / c
        case "(1+c*c/a/a)/4":
            return (1.0 + c * c / a / a) / 4.0
        case "(c*c-b*b)/4/a/a":
            return (c * c - b * b) / 4.0 / a / a
        case "(b*b+c*c)/4/a/a":
            return (b * b + c * c) / 4.0 / a / a
        case "(a*a-c*c)/4/b/b":
            return (a * a - c * c) / 4.0 / b / b
        case "(c*c+a*a)/4/b/b":
            return (c * c + a * a) / 4.0 / b / b
        case "a*a/2/c/c":
            return a * a / 2.0 / c / c
        default:
            return nil
        }
    }
}

// MARK: - Variant path data

/// All SeekPath 2.1.0 band_path_data for the 29 extended Bravais variants.
/// Transcribed from seekpath/hpkot/band_path_data/{variant}/
private enum SeekPathData {

    static func data(for variant: String) -> VariantPathData? {
        switch variant {
        case "cP1": return cP1
        case "cP2": return cP2
        case "cF1": return cF1
        case "cF2": return cF2
        case "cI1": return cI1
        case "tP1": return tP1
        case "tI1": return tI1
        case "tI2": return tI2
        case "oP1": return oP1
        case "oF1": return oF1
        case "oF2": return oF2
        case "oF3": return oF3
        case "oI1": return oI1
        case "oI2": return oI2
        case "oI3": return oI3
        case "oC1": return oC1
        case "oC2": return oC2
        case "oA1": return oA1
        case "oA2": return oA2
        case "hP1": return hP1
        case "hP2": return hP2
        case "hR1": return hR1
        case "hR2": return hR2
        case "mP1": return mP1
        case "mC1": return mC1
        case "mC2": return mC2
        case "mC3": return mC3
        case "aP2": return aP2
        case "aP3": return aP3
        default:
            return nil
        }
    }

    // Helper to create a PointDef
    private static func p(_ label: String, _ x: String, _ y: String, _ z: String) -> PointDef {
        PointDef(label: label, coordExprs: (x, y, z))
    }
    private static func kp(_ name: String, _ expr: String) -> KParamDef {
        KParamDef(name: name, expression: expr)
    }

    // MARK: cP1 (space groups 195-206, cubic primitive with inversion)
    private static let cP1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("R", "1/2", "1/2", "1/2"),
            p("M", "1/2", "1/2", "0"),
            p("X", "0", "1/2", "0"),
            p("X_1", "1/2", "0", "0"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "M"), ("M", "GAMMA"), ("GAMMA", "R"),
            ("R", "X"), ("R", "M"), ("M", "X_1"),
        ]
    )

    // MARK: cP2 (space groups 207-230, cubic primitive no inversion)
    private static let cP2 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("R", "1/2", "1/2", "1/2"),
            p("M", "1/2", "1/2", "0"),
            p("X", "0", "1/2", "0"),
            p("X_1", "1/2", "0", "0"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "M"), ("M", "GAMMA"), ("GAMMA", "R"),
            ("R", "X"), ("R", "M"),
        ]
    )

    // MARK: cF1 (space groups 195-206, cubic face-centered with inversion)
    private static let cF1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "1/2", "0", "1/2"),
            p("L", "1/2", "1/2", "1/2"),
            p("W", "1/2", "1/4", "3/4"),
            p("W_2", "3/4", "1/4", "1/2"),
            p("K", "3/8", "3/8", "3/4"),
            p("U", "5/8", "1/4", "5/8"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "U"), ("K", "GAMMA"), ("GAMMA", "L"),
            ("L", "W"), ("W", "X"), ("X", "W_2"),
        ]
    )

    // MARK: cF2 (space groups 207-230, cubic face-centered no inversion)
    private static let cF2 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "1/2", "0", "1/2"),
            p("L", "1/2", "1/2", "1/2"),
            p("W", "1/2", "1/4", "3/4"),
            p("W_2", "3/4", "1/4", "1/2"),
            p("K", "3/8", "3/8", "3/4"),
            p("U", "5/8", "1/4", "5/8"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "U"), ("K", "GAMMA"), ("GAMMA", "L"),
            ("L", "W"), ("W", "X"),
        ]
    )

    // MARK: cI1 (cubic body-centered)
    private static let cI1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("H", "1/2", "-1/2", "1/2"),
            p("P", "1/4", "1/4", "1/4"),
            p("N", "0", "0", "1/2"),
        ],
        edges: [
            ("GAMMA", "H"), ("H", "N"), ("N", "GAMMA"), ("GAMMA", "P"),
            ("P", "H"), ("P", "N"),
        ]
    )

    // MARK: tP1 (tetragonal primitive)
    private static let tP1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Z", "0", "0", "1/2"),
            p("M", "1/2", "1/2", "0"),
            p("A", "1/2", "1/2", "1/2"),
            p("R", "0", "1/2", "1/2"),
            p("X", "0", "1/2", "0"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "M"), ("M", "GAMMA"), ("GAMMA", "Z"),
            ("Z", "R"), ("R", "A"), ("A", "Z"), ("X", "R"), ("M", "A"),
        ]
    )

    // MARK: tI1 (tetragonal body-centered, c <= a)
    private static let tI1 = VariantPathData(
        kParams: [
            kp("H", "(1+c*c/a/a)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("M", "-1/2", "1/2", "1/2"),
            p("X", "0", "0", "1/2"),
            p("P", "1/4", "1/4", "1/4"),
            p("Z", "H", "H", "-H"),
            p("Z_0", "-H", "1-H", "H"),
            p("N", "0", "1/2", "0"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "M"), ("M", "GAMMA"), ("GAMMA", "Z"),
            ("Z_0", "M"), ("X", "P"), ("P", "N"), ("N", "GAMMA"),
        ]
    )

    // MARK: tI2 (tetragonal body-centered, c > a)
    private static let tI2 = VariantPathData(
        kParams: [
            kp("H", "(1+a*a/c/c)/4"),
            kp("Z", "a*a/2/c/c"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("M", "1/2", "1/2", "-1/2"),
            p("X", "0", "0", "1/2"),
            p("P", "1/4", "1/4", "1/4"),
            p("N", "0", "1/2", "0"),
            p("S_0", "-H", "H", "H"),
            p("S", "H", "1-H", "-H"),
            p("R", "-Z", "Z", "1/2"),
            p("G", "1/2", "1/2", "-Z"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "P"), ("P", "N"), ("N", "GAMMA"),
            ("GAMMA", "M"), ("M", "S"), ("S_0", "GAMMA"), ("X", "R"), ("G", "M"),
        ]
    )

    // MARK: oP1 (orthorhombic primitive)
    private static let oP1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "1/2", "0", "0"),
            p("Z", "0", "0", "1/2"),
            p("U", "1/2", "0", "1/2"),
            p("Y", "0", "1/2", "0"),
            p("S", "1/2", "1/2", "0"),
            p("T", "0", "1/2", "1/2"),
            p("R", "1/2", "1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "S"), ("S", "Y"), ("Y", "GAMMA"),
            ("GAMMA", "Z"), ("Z", "U"), ("U", "R"), ("R", "T"), ("T", "Z"),
            ("X", "U"), ("Y", "T"), ("S", "R"),
        ]
    )

    // MARK: oF1 (orthorhombic face-centered, 1/a^2 > 1/b^2 + 1/c^2)
    private static let oF1 = VariantPathData(
        kParams: [
            kp("J", "(1+a*a/b/b-a*a/c/c)/4"),
            kp("H", "(1+a*a/b/b+a*a/c/c)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("T", "1", "1/2", "1/2"),
            p("Z", "1/2", "1/2", "0"),
            p("Y", "1/2", "0", "1/2"),
            p("SIGMA_0", "0", "H", "H"),
            p("U_0", "1", "1-H", "1-H"),
            p("A_0", "1/2", "1/2+J", "J"),
            p("C_0", "1/2", "1/2-J", "1-J"),
            p("L", "1/2", "1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "T"), ("T", "Z"), ("Z", "GAMMA"),
            ("GAMMA", "SIGMA_0"), ("U_0", "T"), ("Y", "C_0"), ("A_0", "Z"),
            ("GAMMA", "L"),
        ]
    )

    // MARK: oF2 (orthorhombic face-centered, 1/c^2 > 1/a^2 + 1/b^2)
    private static let oF2 = VariantPathData(
        kParams: [
            kp("J", "(1+c*c/a/a-c*c/b/b)/4"),
            kp("K", "(1+c*c/a/a+c*c/b/b)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("T", "0", "1/2", "1/2"),
            p("Z", "1/2", "1/2", "1"),
            p("Y", "1/2", "0", "1/2"),
            p("LAMBDA_0", "K", "K", "0"),
            p("Q_0", "1-K", "1-K", "1"),
            p("G_0", "1/2-J", "1-J", "1/2"),
            p("H_0", "1/2+J", "J", "1/2"),
            p("L", "1/2", "1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "T"), ("T", "Z"), ("Z", "Y"), ("Y", "GAMMA"),
            ("GAMMA", "LAMBDA_0"), ("Q_0", "Z"), ("T", "G_0"), ("H_0", "Y"),
            ("GAMMA", "L"),
        ]
    )

    // MARK: oF3 (orthorhombic face-centered, triangle case)
    private static let oF3 = VariantPathData(
        kParams: [
            kp("H", "(1+a*a/b/b-a*a/c/c)/4"),
            kp("K", "(1+b*b/a/a-b*b/c/c)/4"),
            kp("P", "(1+c*c/b/b-c*c/a/a)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("T", "0", "1/2", "1/2"),
            p("Z", "1/2", "1/2", "0"),
            p("Y", "1/2", "0", "1/2"),
            p("A_0", "1/2", "1/2+H", "H"),
            p("C_0", "1/2", "1/2-H", "1-H"),
            p("B_0", "1/2+K", "1/2", "K"),
            p("D_0", "1/2-K", "1/2", "1-K"),
            p("G_0", "P", "1/2+P", "1/2"),
            p("H_0", "1-P", "1/2-P", "1/2"),
            p("L", "1/2", "1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "C_0"), ("A_0", "Z"), ("Z", "B_0"),
            ("D_0", "T"), ("T", "G_0"), ("H_0", "Y"), ("T", "GAMMA"),
            ("GAMMA", "Z"), ("GAMMA", "L"),
        ]
    )

    // MARK: oI1 (orthorhombic body-centered, a largest)
    private static let oI1 = VariantPathData(
        kParams: [
            kp("Z", "(1+a*a/c/c)/4"),
            kp("H", "(1+b*b/c/c)/4"),
            kp("D", "(b*b-a*a)/4/c/c"),
            kp("N", "(a*a+b*b)/4/c/c"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "1/2", "1/2", "-1/2"),
            p("S", "1/2", "0", "0"),
            p("R", "0", "1/2", "0"),
            p("T", "0", "0", "1/2"),
            p("W", "1/4", "1/4", "1/4"),
            p("SIGMA_0", "-Z", "Z", "Z"),
            p("F_2", "Z", "1-Z", "-Z"),
            p("Y_0", "H", "-H", "H"),
            p("U_0", "1-H", "H", "-H"),
            p("L_0", "-N", "N", "1/2-D"),
            p("M_0", "N", "-N", "1/2+D"),
            p("J_0", "1/2-D", "1/2+D", "-N"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "F_2"), ("SIGMA_0", "GAMMA"), ("GAMMA", "Y_0"),
            ("U_0", "X"), ("GAMMA", "R"), ("R", "W"), ("W", "S"), ("S", "GAMMA"),
            ("GAMMA", "T"), ("T", "W"),
        ]
    )

    // MARK: oI2 (orthorhombic body-centered, b largest)
    private static let oI2 = VariantPathData(
        kParams: [
            kp("Z", "(1+b*b/a/a)/4"),
            kp("H", "(1+c*c/a/a)/4"),
            kp("D", "(c*c-b*b)/4/a/a"),
            kp("N", "(b*b+c*c)/4/a/a"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "-1/2", "1/2", "1/2"),
            p("S", "1/2", "0", "0"),
            p("R", "0", "1/2", "0"),
            p("T", "0", "0", "1/2"),
            p("W", "1/4", "1/4", "1/4"),
            p("Y_0", "Z", "-Z", "Z"),
            p("U_2", "-Z", "Z", "1-Z"),
            p("LAMBDA_0", "H", "H", "-H"),
            p("G_2", "-H", "1-H", "H"),
            p("K", "1/2-D", "-N", "N"),
            p("K_2", "1/2+D", "N", "-N"),
            p("K_4", "-N", "1/2-D", "1/2+D"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "U_2"), ("Y_0", "GAMMA"), ("GAMMA", "LAMBDA_0"),
            ("G_2", "X"), ("GAMMA", "R"), ("R", "W"), ("W", "S"), ("S", "GAMMA"),
            ("GAMMA", "T"), ("T", "W"),
        ]
    )

    // MARK: oI3 (orthorhombic body-centered, c largest)
    private static let oI3 = VariantPathData(
        kParams: [
            kp("Z", "(1+c*c/b/b)/4"),
            kp("Y", "(1+a*a/b/b)/4"),
            kp("D", "(a*a-c*c)/4/b/b"),
            kp("M", "(c*c+a*a)/4/b/b"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("X", "1/2", "-1/2", "1/2"),
            p("S", "1/2", "0", "0"),
            p("R", "0", "1/2", "0"),
            p("T", "0", "0", "1/2"),
            p("W", "1/4", "1/4", "1/4"),
            p("SIGMA_0", "-Y", "Y", "Y"),
            p("F_0", "Y", "-Y", "1-Y"),
            p("LAMBDA_0", "Z", "Z", "-Z"),
            p("G_0", "1-Z", "-Z", "Z"),
            p("V_0", "M", "1/2-D", "-M"),
            p("H_0", "-M", "1/2+D", "M"),
            p("H_2", "1/2+D", "-M", "1/2-D"),
        ],
        edges: [
            ("GAMMA", "X"), ("X", "F_0"), ("SIGMA_0", "GAMMA"), ("GAMMA", "LAMBDA_0"),
            ("G_0", "X"), ("GAMMA", "R"), ("R", "W"), ("W", "S"), ("S", "GAMMA"),
            ("GAMMA", "T"), ("T", "W"),
        ]
    )

    // MARK: oC1 (orthorhombic base-centered, a <= b)
    private static let oC1 = VariantPathData(
        kParams: [
            kp("X", "(1+a*a/b/b)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "-1/2", "1/2", "0"),
            p("T", "-1/2", "1/2", "1/2"),
            p("Z", "0", "0", "1/2"),
            p("S", "0", "1/2", "0"),
            p("R", "0", "1/2", "1/2"),
            p("SIGMA_0", "X", "X", "0"),
            p("C_0", "-X", "1-X", "0"),
            p("A_0", "X", "X", "1/2"),
            p("E_0", "-X", "1-X", "1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "C_0"), ("SIGMA_0", "GAMMA"), ("GAMMA", "Z"),
            ("Z", "A_0"), ("E_0", "T"), ("T", "Y"), ("GAMMA", "S"), ("S", "R"),
            ("R", "Z"), ("Z", "T"),
        ]
    )

    // MARK: oC2 (orthorhombic base-centered, b < a)
    private static let oC2 = VariantPathData(
        kParams: [
            kp("X", "(1+b*b/a/a)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "1/2", "1/2", "0"),
            p("T", "1/2", "1/2", "1/2"),
            p("T_2", "1/2", "1/2", "-1/2"),
            p("Z", "0", "0", "1/2"),
            p("Z_2", "0", "0", "-1/2"),
            p("S", "0", "1/2", "0"),
            p("R", "0", "1/2", "1/2"),
            p("R_2", "0", "1/2", "-1/2"),
            p("DELTA_0", "-X", "X", "0"),
            p("F_0", "X", "1-X", "0"),
            p("B_0", "-X", "X", "1/2"),
            p("B_2", "-X", "X", "-1/2"),
            p("G_0", "X", "1-X", "1/2"),
            p("G_2", "X", "1-X", "-1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "F_0"), ("DELTA_0", "GAMMA"), ("GAMMA", "Z"),
            ("Z", "B_0"), ("G_0", "T"), ("T", "Y"), ("GAMMA", "S"), ("S", "R"),
            ("R", "Z"), ("Z", "T"),
        ]
    )

    // MARK: oA1 (orthorhombic A-centered, b <= c)
    private static let oA1 = VariantPathData(
        kParams: [
            kp("X", "(1+b*b/c/c)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "-1/2", "1/2", "0"),
            p("T", "-1/2", "1/2", "1/2"),
            p("Z", "0", "0", "1/2"),
            p("S", "0", "1/2", "0"),
            p("R", "0", "1/2", "1/2"),
            p("SIGMA_0", "X", "X", "0"),
            p("C_0", "-X", "1-X", "0"),
            p("A_0", "X", "X", "1/2"),
            p("E_0", "-X", "1-X", "1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "C_0"), ("SIGMA_0", "GAMMA"), ("GAMMA", "Z"),
            ("Z", "A_0"), ("E_0", "T"), ("T", "Y"), ("GAMMA", "S"), ("S", "R"),
            ("R", "Z"), ("Z", "T"),
        ]
    )

    // MARK: oA2 (orthorhombic A-centered, c < b)
    private static let oA2 = VariantPathData(
        kParams: [
            kp("X", "(1+c*c/b/b)/4"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "1/2", "1/2", "0"),
            p("T", "1/2", "1/2", "1/2"),
            p("T_2", "1/2", "1/2", "-1/2"),
            p("Z", "0", "0", "1/2"),
            p("Z_2", "0", "0", "-1/2"),
            p("S", "0", "1/2", "0"),
            p("R", "0", "1/2", "1/2"),
            p("R_2", "0", "1/2", "-1/2"),
            p("DELTA_0", "-X", "X", "0"),
            p("F_0", "X", "1-X", "0"),
            p("B_0", "-X", "X", "1/2"),
            p("B_2", "-X", "X", "-1/2"),
            p("G_0", "X", "1-X", "1/2"),
            p("G_2", "X", "1-X", "-1/2"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "F_0"), ("DELTA_0", "GAMMA"), ("GAMMA", "Z"),
            ("Z", "B_0"), ("G_0", "T"), ("T", "Y"), ("GAMMA", "S"), ("S", "R"),
            ("R", "Z"), ("Z", "T"),
        ]
    )

    // MARK: hP1 (hexagonal, specific space groups)
    private static let hP1 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("A", "0", "0", "1/2"),
            p("K", "1/3", "1/3", "0"),
            p("H", "1/3", "1/3", "1/2"),
            p("H_2", "1/3", "1/3", "-1/2"),
            p("M", "1/2", "0", "0"),
            p("L", "1/2", "0", "1/2"),
        ],
        edges: [
            ("GAMMA", "M"), ("M", "K"), ("K", "GAMMA"), ("GAMMA", "A"),
            ("A", "L"), ("L", "H"), ("H", "A"), ("L", "M"), ("H", "K"),
            ("K", "H_2"),
        ]
    )

    // MARK: hP2 (hexagonal, other space groups)
    private static let hP2 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("A", "0", "0", "1/2"),
            p("K", "1/3", "1/3", "0"),
            p("H", "1/3", "1/3", "1/2"),
            p("H_2", "1/3", "1/3", "-1/2"),
            p("M", "1/2", "0", "0"),
            p("L", "1/2", "0", "1/2"),
        ],
        edges: [
            ("GAMMA", "M"), ("M", "K"), ("K", "GAMMA"), ("GAMMA", "A"),
            ("A", "L"), ("L", "H"), ("H", "A"), ("L", "M"), ("H", "K"),
        ]
    )

    // MARK: hR1 (trigonal rhombohedral, sqrt(3)a <= sqrt(2)c)
    private static let hR1 = VariantPathData(
        kParams: [
            kp("D", "a*a/4/c/c"),
            kp("Y", "5/6-2*D"),
            kp("N", "1/3+D"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("T", "1/2", "1/2", "1/2"),
            p("L", "1/2", "0", "0"),
            p("L_2", "0", "-1/2", "0"),
            p("L_4", "0", "0", "-1/2"),
            p("F", "1/2", "0", "1/2"),
            p("F_2", "1/2", "1/2", "0"),
            p("S_0", "N", "-N", "0"),
            p("S_2", "1-N", "0", "N"),
            p("S_4", "N", "0", "-N"),
            p("S_6", "1-N", "N", "0"),
            p("H_0", "1/2", "-1+Y", "1-Y"),
            p("H_2", "Y", "1-Y", "1/2"),
            p("H_4", "Y", "1/2", "1-Y"),
            p("H_6", "1/2", "1-Y", "-1+Y"),
            p("M_0", "N", "-1+Y", "N"),
            p("M_2", "1-N", "1-Y", "1-N"),
            p("M_4", "Y", "N", "N"),
            p("M_6", "1-N", "1-N", "1-Y"),
            p("M_8", "N", "N", "-1+Y"),
        ],
        edges: [
            ("GAMMA", "T"), ("T", "H_2"), ("H_0", "L"), ("L", "GAMMA"),
            ("GAMMA", "S_0"), ("S_2", "F"), ("F", "GAMMA"),
        ]
    )

    // MARK: hR2 (trigonal rhombohedral, sqrt(3)a > sqrt(2)c)
    private static let hR2 = VariantPathData(
        kParams: [
            kp("Z", "1/6-c*c/9/a/a"),
            kp("H", "1/2-2*Z"),
            kp("N", "1/2+Z"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("T", "1/2", "-1/2", "1/2"),
            p("P_0", "H", "-1+H", "H"),
            p("P_2", "H", "H", "H"),
            p("R_0", "1-H", "-H", "-H"),
            p("M", "1-N", "-N", "1-N"),
            p("M_2", "N", "-1+N", "-1+N"),
            p("L", "1/2", "0", "0"),
            p("F", "1/2", "-1/2", "0"),
        ],
        edges: [
            ("GAMMA", "L"), ("L", "T"), ("T", "P_0"), ("P_2", "GAMMA"),
            ("GAMMA", "F"),
        ]
    )

    // MARK: mP1 (monoclinic primitive)
    private static let mP1 = VariantPathData(
        kParams: [
            kp("Y", "(1+a/c*cosbeta)/2/sinbeta/sinbeta"),
            kp("N", "1/2+Y*c*cosbeta/a"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Z", "0", "1/2", "0"),
            p("B", "0", "0", "1/2"),
            p("B_2", "0", "0", "-1/2"),
            p("Y", "1/2", "0", "0"),
            p("Y_2", "-1/2", "0", "0"),
            p("C", "1/2", "1/2", "0"),
            p("C_2", "-1/2", "1/2", "0"),
            p("D", "0", "1/2", "1/2"),
            p("D_2", "0", "1/2", "-1/2"),
            p("A", "-1/2", "0", "1/2"),
            p("E", "-1/2", "1/2", "1/2"),
            p("H", "-Y", "0", "1-N"),
            p("H_2", "-1+Y", "0", "N"),
            p("H_4", "-Y", "0", "-N"),
            p("M", "-Y", "1/2", "1-N"),
            p("M_2", "-1+Y", "1/2", "N"),
            p("M_4", "-Y", "1/2", "-N"),
        ],
        edges: [
            ("GAMMA", "Z"), ("Z", "D"), ("D", "B"), ("B", "GAMMA"),
            ("GAMMA", "A"), ("A", "E"), ("E", "Z"), ("Z", "C_2"), ("C_2", "Y_2"),
            ("Y_2", "GAMMA"),
        ]
    )

    // MARK: mC1 (monoclinic base-centered, b < a*sin(beta))
    private static let mC1 = VariantPathData(
        kParams: [
            kp("Z", "(2+a/c*cosbeta)/4/sinbeta/sinbeta"),
            kp("H", "1/2-2*Z*c*cosbeta/a"),
            kp("S", "3/4-b*b/4/a/a/sinbeta/sinbeta"),
            kp("P", "S-(3/4-S)*a*cosbeta/c"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y_2", "-1/2", "1/2", "0"),
            p("Y_4", "1/2", "-1/2", "0"),
            p("A", "0", "0", "1/2"),
            p("M_2", "-1/2", "1/2", "1/2"),
            p("V", "1/2", "0", "0"),
            p("V_2", "0", "1/2", "0"),
            p("L_2", "0", "1/2", "1/2"),
            p("C", "1-S", "1-S", "0"),
            p("C_2", "-1+S", "S", "0"),
            p("C_4", "S", "-1+S", "0"),
            p("D", "-1+P", "P", "1/2"),
            p("D_2", "1-P", "1-P", "1/2"),
            p("E", "-1+Z", "1-Z", "1-H"),
            p("E_2", "-Z", "Z", "H"),
            p("E_4", "Z", "-Z", "1-H"),
        ],
        edges: [
            ("GAMMA", "C"), ("C_2", "Y_2"), ("Y_2", "GAMMA"), ("GAMMA", "M_2"),
            ("M_2", "D"), ("D_2", "A"), ("A", "GAMMA"), ("L_2", "GAMMA"),
            ("GAMMA", "V_2"),
        ]
    )

    // MARK: mC2 (monoclinic base-centered, 12-face case)
    private static let mC2 = VariantPathData(
        kParams: [
            kp("Z", "(a*a/b/b+(1+a/c*cosbeta)/sinbeta/sinbeta)/4"),
            kp("M", "(1+a*a/b/b)/4"),
            kp("D", "-a*c*cosbeta/2/b/b"),
            kp("X", "1/2-2*Z*c*cosbeta/a"),
            kp("P", "1+Z-2*M"),
            kp("S", "X-2*D"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "1/2", "1/2", "0"),
            p("A", "0", "0", "1/2"),
            p("M", "1/2", "1/2", "1/2"),
            p("V_2", "0", "1/2", "0"),
            p("L_2", "0", "1/2", "1/2"),
            p("F", "-1+P", "1-P", "1-S"),
            p("F_2", "1-P", "P", "S"),
            p("F_4", "P", "1-P", "1-S"),
            p("H", "-Z", "Z", "X"),
            p("H_2", "Z", "1-Z", "1-X"),
            p("H_4", "Z", "-Z", "1-X"),
            p("G", "-M", "M", "D"),
            p("G_2", "M", "1-M", "-D"),
            p("G_4", "M", "-M", "-D"),
            p("G_6", "1-M", "M", "D"),
        ],
        edges: [
            ("GAMMA", "Y"), ("Y", "M"), ("M", "A"), ("A", "GAMMA"),
            ("L_2", "GAMMA"), ("GAMMA", "V_2"),
        ]
    )

    // MARK: mC3 (monoclinic base-centered, not 12-face case)
    private static let mC3 = VariantPathData(
        kParams: [
            kp("Z", "(a*a/b/b+(1+a/c*cosbeta)/sinbeta/sinbeta)/4"),
            kp("R", "1-Z*b*b/a/a"),
            kp("E", "1/2-2*Z*c*cosbeta/a"),
            kp("F", "E/2+a*a/4/b/b+a*c*cosbeta/2/b/b"),
            kp("U", "2*F-Z"),
            kp("W", "c/2/a/cosbeta*(1-4*U+a*a*sinbeta*sinbeta/b/b)"),
            kp("D", "-1/4+W/2-Z*c*cosbeta/a"),
        ],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Y", "1/2", "1/2", "0"),
            p("A", "0", "0", "1/2"),
            p("M_2", "-1/2", "1/2", "1/2"),
            p("V", "1/2", "0", "0"),
            p("V_2", "0", "1/2", "0"),
            p("L_2", "0", "1/2", "1/2"),
            p("I", "-1+R", "R", "1/2"),
            p("I_2", "1-R", "1-R", "1/2"),
            p("K", "-U", "U", "W"),
            p("K_2", "-1+U", "1-U", "1-W"),
            p("K_4", "1-U", "U", "W"),
            p("H", "-Z", "Z", "E"),
            p("H_2", "Z", "1-Z", "1-E"),
            p("H_4", "Z", "-Z", "1-E"),
            p("N", "-F", "F", "D"),
            p("N_2", "F", "1-F", "-D"),
            p("N_4", "F", "-F", "-D"),
            p("N_6", "1-F", "F", "D"),
        ],
        edges: [
            ("GAMMA", "A"), ("A", "I_2"), ("I", "M_2"), ("M_2", "GAMMA"),
            ("GAMMA", "Y"), ("L_2", "GAMMA"), ("GAMMA", "V_2"),
        ]
    )

    // MARK: aP2 (triclinic, all-obtuse reciprocal)
    private static let aP2 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Z", "0", "0", "1/2"),
            p("Y", "0", "1/2", "0"),
            p("X", "1/2", "0", "0"),
            p("V", "1/2", "1/2", "0"),
            p("U", "1/2", "0", "1/2"),
            p("T", "0", "1/2", "1/2"),
            p("R", "1/2", "1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "X"), ("Y", "GAMMA"), ("GAMMA", "Z"), ("R", "GAMMA"),
            ("GAMMA", "T"), ("U", "GAMMA"), ("GAMMA", "V"),
        ]
    )

    // MARK: aP3 (triclinic, all-acute reciprocal)
    private static let aP3 = VariantPathData(
        kParams: [],
        points: [
            p("GAMMA", "0", "0", "0"),
            p("Z", "0", "0", "1/2"),
            p("Y", "0", "1/2", "0"),
            p("Y_2", "0", "-1/2", "0"),
            p("X", "1/2", "0", "0"),
            p("V_2", "1/2", "-1/2", "0"),
            p("U_2", "-1/2", "0", "1/2"),
            p("T_2", "0", "-1/2", "1/2"),
            p("R_2", "-1/2", "-1/2", "1/2"),
        ],
        edges: [
            ("GAMMA", "X"), ("Y", "GAMMA"), ("GAMMA", "Z"), ("R_2", "GAMMA"),
            ("GAMMA", "T_2"), ("U_2", "GAMMA"), ("GAMMA", "V_2"),
        ]
    )
}

// MARK: - Variant selection

/// Select the extended Bravais variant from the space group number and
/// conventional cell parameters. Follows seekpath/hpkot/__init__.py logic.
/// Variant selector. Selects the extended Bravais variant from the space
/// group number and conventional cell parameters. Follows seekpath/hpkot/__init__.py
/// logic. Returns nil for unknown/unclassifiable cases so malformed data does
/// not trap.
enum VariantSelect {

    /// Authoritative space-group → (crystal_family, centering, has_inversion)
    /// mapping from seekpath/hpkot/spg_db.py spgroup_data. This is the canonical
    /// source of truth for Bravais-family/centering selection, replacing the
    /// unreliable spglib-detected centering that can change under rotation.
    static let spgDbData: [Int: (family: String, centering: String, hasInversion: Bool)] = {
        var dict: [Int: (family: String, centering: String, hasInversion: Bool)] = [:]
        dict[1] = ("a", "P", false)
        dict[2] = ("a", "P", true)
        dict[3] = ("m", "P", false)
        dict[4] = ("m", "P", false)
        dict[5] = ("m", "C", false)
        dict[6] = ("m", "P", false)
        dict[7] = ("m", "P", false)
        dict[8] = ("m", "C", false)
        dict[9] = ("m", "C", false)
        dict[10] = ("m", "P", true)
        dict[11] = ("m", "P", true)
        dict[12] = ("m", "C", true)
        dict[13] = ("m", "P", true)
        dict[14] = ("m", "P", true)
        dict[15] = ("m", "C", true)
        dict[16] = ("o", "P", false)
        dict[17] = ("o", "P", false)
        dict[18] = ("o", "P", false)
        dict[19] = ("o", "P", false)
        dict[20] = ("o", "C", false)
        dict[21] = ("o", "C", false)
        dict[22] = ("o", "F", false)
        dict[23] = ("o", "I", false)
        dict[24] = ("o", "I", false)
        dict[25] = ("o", "P", false)
        dict[26] = ("o", "P", false)
        dict[27] = ("o", "P", false)
        dict[28] = ("o", "P", false)
        dict[29] = ("o", "P", false)
        dict[30] = ("o", "P", false)
        dict[31] = ("o", "P", false)
        dict[32] = ("o", "P", false)
        dict[33] = ("o", "P", false)
        dict[34] = ("o", "P", false)
        dict[35] = ("o", "C", false)
        dict[36] = ("o", "C", false)
        dict[37] = ("o", "C", false)
        dict[38] = ("o", "A", false)
        dict[39] = ("o", "A", false)
        dict[40] = ("o", "A", false)
        dict[41] = ("o", "A", false)
        dict[42] = ("o", "F", false)
        dict[43] = ("o", "F", false)
        dict[44] = ("o", "I", false)
        dict[45] = ("o", "I", false)
        dict[46] = ("o", "I", false)
        dict[47] = ("o", "P", true)
        dict[48] = ("o", "P", true)
        dict[49] = ("o", "P", true)
        dict[50] = ("o", "P", true)
        dict[51] = ("o", "P", true)
        dict[52] = ("o", "P", true)
        dict[53] = ("o", "P", true)
        dict[54] = ("o", "P", true)
        dict[55] = ("o", "P", true)
        dict[56] = ("o", "P", true)
        dict[57] = ("o", "P", true)
        dict[58] = ("o", "P", true)
        dict[59] = ("o", "P", true)
        dict[60] = ("o", "P", true)
        dict[61] = ("o", "P", true)
        dict[62] = ("o", "P", true)
        dict[63] = ("o", "C", true)
        dict[64] = ("o", "C", true)
        dict[65] = ("o", "C", true)
        dict[66] = ("o", "C", true)
        dict[67] = ("o", "C", true)
        dict[68] = ("o", "C", true)
        dict[69] = ("o", "F", true)
        dict[70] = ("o", "F", true)
        dict[71] = ("o", "I", true)
        dict[72] = ("o", "I", true)
        dict[73] = ("o", "I", true)
        dict[74] = ("o", "I", true)
        dict[75] = ("t", "P", false)
        dict[76] = ("t", "P", false)
        dict[77] = ("t", "P", false)
        dict[78] = ("t", "P", false)
        dict[79] = ("t", "I", false)
        dict[80] = ("t", "I", false)
        dict[81] = ("t", "P", false)
        dict[82] = ("t", "I", false)
        dict[83] = ("t", "P", true)
        dict[84] = ("t", "P", true)
        dict[85] = ("t", "P", true)
        dict[86] = ("t", "P", true)
        dict[87] = ("t", "I", true)
        dict[88] = ("t", "I", true)
        dict[89] = ("t", "P", false)
        dict[90] = ("t", "P", false)
        dict[91] = ("t", "P", false)
        dict[92] = ("t", "P", false)
        dict[93] = ("t", "P", false)
        dict[94] = ("t", "P", false)
        dict[95] = ("t", "P", false)
        dict[96] = ("t", "P", false)
        dict[97] = ("t", "I", false)
        dict[98] = ("t", "I", false)
        dict[99] = ("t", "P", false)
        dict[100] = ("t", "P", false)
        dict[101] = ("t", "P", false)
        dict[102] = ("t", "P", false)
        dict[103] = ("t", "P", false)
        dict[104] = ("t", "P", false)
        dict[105] = ("t", "P", false)
        dict[106] = ("t", "P", false)
        dict[107] = ("t", "I", false)
        dict[108] = ("t", "I", false)
        dict[109] = ("t", "I", false)
        dict[110] = ("t", "I", false)
        dict[111] = ("t", "P", false)
        dict[112] = ("t", "P", false)
        dict[113] = ("t", "P", false)
        dict[114] = ("t", "P", false)
        dict[115] = ("t", "P", false)
        dict[116] = ("t", "P", false)
        dict[117] = ("t", "P", false)
        dict[118] = ("t", "P", false)
        dict[119] = ("t", "I", false)
        dict[120] = ("t", "I", false)
        dict[121] = ("t", "I", false)
        dict[122] = ("t", "I", false)
        dict[123] = ("t", "P", true)
        dict[124] = ("t", "P", true)
        dict[125] = ("t", "P", true)
        dict[126] = ("t", "P", true)
        dict[127] = ("t", "P", true)
        dict[128] = ("t", "P", true)
        dict[129] = ("t", "P", true)
        dict[130] = ("t", "P", true)
        dict[131] = ("t", "P", true)
        dict[132] = ("t", "P", true)
        dict[133] = ("t", "P", true)
        dict[134] = ("t", "P", true)
        dict[135] = ("t", "P", true)
        dict[136] = ("t", "P", true)
        dict[137] = ("t", "P", true)
        dict[138] = ("t", "P", true)
        dict[139] = ("t", "I", true)
        dict[140] = ("t", "I", true)
        dict[141] = ("t", "I", true)
        dict[142] = ("t", "I", true)
        dict[143] = ("h", "P", false)
        dict[144] = ("h", "P", false)
        dict[145] = ("h", "P", false)
        dict[146] = ("h", "R", false)
        dict[147] = ("h", "P", true)
        dict[148] = ("h", "R", true)
        dict[149] = ("h", "P", false)
        dict[150] = ("h", "P", false)
        dict[151] = ("h", "P", false)
        dict[152] = ("h", "P", false)
        dict[153] = ("h", "P", false)
        dict[154] = ("h", "P", false)
        dict[155] = ("h", "R", false)
        dict[156] = ("h", "P", false)
        dict[157] = ("h", "P", false)
        dict[158] = ("h", "P", false)
        dict[159] = ("h", "P", false)
        dict[160] = ("h", "R", false)
        dict[161] = ("h", "R", false)
        dict[162] = ("h", "P", true)
        dict[163] = ("h", "P", true)
        dict[164] = ("h", "P", true)
        dict[165] = ("h", "P", true)
        dict[166] = ("h", "R", true)
        dict[167] = ("h", "R", true)
        dict[168] = ("h", "P", false)
        dict[169] = ("h", "P", false)
        dict[170] = ("h", "P", false)
        dict[171] = ("h", "P", false)
        dict[172] = ("h", "P", false)
        dict[173] = ("h", "P", false)
        dict[174] = ("h", "P", false)
        dict[175] = ("h", "P", true)
        dict[176] = ("h", "P", true)
        dict[177] = ("h", "P", false)
        dict[178] = ("h", "P", false)
        dict[179] = ("h", "P", false)
        dict[180] = ("h", "P", false)
        dict[181] = ("h", "P", false)
        dict[182] = ("h", "P", false)
        dict[183] = ("h", "P", false)
        dict[184] = ("h", "P", false)
        dict[185] = ("h", "P", false)
        dict[186] = ("h", "P", false)
        dict[187] = ("h", "P", false)
        dict[188] = ("h", "P", false)
        dict[189] = ("h", "P", false)
        dict[190] = ("h", "P", false)
        dict[191] = ("h", "P", true)
        dict[192] = ("h", "P", true)
        dict[193] = ("h", "P", true)
        dict[194] = ("h", "P", true)
        dict[195] = ("c", "P", false)
        dict[196] = ("c", "F", false)
        dict[197] = ("c", "I", false)
        dict[198] = ("c", "P", false)
        dict[199] = ("c", "I", false)
        dict[200] = ("c", "P", true)
        dict[201] = ("c", "P", true)
        dict[202] = ("c", "F", true)
        dict[203] = ("c", "F", true)
        dict[204] = ("c", "I", true)
        dict[205] = ("c", "P", true)
        dict[206] = ("c", "I", true)
        dict[207] = ("c", "P", false)
        dict[208] = ("c", "P", false)
        dict[209] = ("c", "F", false)
        dict[210] = ("c", "F", false)
        dict[211] = ("c", "I", false)
        dict[212] = ("c", "P", false)
        dict[213] = ("c", "P", false)
        dict[214] = ("c", "I", false)
        dict[215] = ("c", "P", false)
        dict[216] = ("c", "F", false)
        dict[217] = ("c", "I", false)
        dict[218] = ("c", "P", false)
        dict[219] = ("c", "F", false)
        dict[220] = ("c", "I", false)
        dict[221] = ("c", "P", true)
        dict[222] = ("c", "P", true)
        dict[223] = ("c", "P", true)
        dict[224] = ("c", "P", true)
        dict[225] = ("c", "F", true)
        dict[226] = ("c", "F", true)
        dict[227] = ("c", "F", true)
        dict[228] = ("c", "F", true)
        dict[229] = ("c", "I", true)
        dict[230] = ("c", "I", true)
        return dict
    }()

    /// Convert spg_db centering letter to CrystalCentering.
    static func centeringFromSpg(_ sg: Int) -> CrystalCentering? {
        guard let data = spgDbData[sg] else { return nil }
        return CrystalCentering(rawValue: data.centering)
    }

    /// HPKOT P matrices from seekpath/hpkot/spg_mapping.py get_P_matrix.
    /// Converts conventional lattice (rows = basis vectors) to primitive:
    ///   prim_lattice = P.T @ conv_lattice
    /// Stored row-major. Returns nil for unknown Bravais strings.
    static func pMatrix(for bravaisLattice: String) -> [Double]? {
        switch bravaisLattice {
        case "cP", "tP", "hP", "oP", "mP":
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        case "cF", "oF":
            return [0, 0.5, 0.5, 0.5, 0, 0.5, 0.5, 0.5, 0]
        case "cI", "tI", "oI":
            return [-0.5, 0.5, 0.5, 0.5, -0.5, 0.5, 0.5, 0.5, -0.5]
        case "hR":
            return [2.0/3, -1.0/3, -1.0/3, 1.0/3, 1.0/3, -2.0/3, 1.0/3, 1.0/3, 1.0/3]
        case "oC":
            return [0.5, 0.5, 0, -0.5, 0.5, 0, 0, 0, 1]
        case "oA":
            return [0, 0, 1, 0.5, 0.5, 0, -0.5, 0.5, 0]
        case "mC":
            return [0.5, -0.5, 0, 0.5, 0.5, 0, 0, 0, 1]
        case "aP":
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        default:
            return nil
        }
    }

    /// Extract the Bravais lattice string (e.g., "cF", "hR") from a variant name
    /// (e.g., "cF1", "hR2") by stripping the trailing digit.
    static func bravaisLatticeString(for variant: String) -> String {
        var s = variant
        while let last = s.last, last.isNumber {
            s.removeLast()
        }
        return s
    }

    static func select(spaceGroup: Int, a: Double, b: Double, c: Double,
                       cosalpha: Double, cosbeta: Double, cosgamma: Double,
                       centering: CrystalCentering, hallNumber: Int?,
                       standardizedLattice: CrystalSymmetryMatrix,
                       transformation: CrystalSymmetryMatrix) -> (variant: String, realCellFinal: [Double]?)? {
        // Keep this selector safe when it is called through the testable seam
        // as well as from a validated CrystalSymmetry. The metric formulas
        // below divide by a/b/c and the monoclinic branch takes sqrt(1-cos²),
        // so non-finite or geometrically impossible parameters must be a
        // recoverable failure rather than propagating NaN through a route.
        guard (1...230).contains(spaceGroup),
              a.isFinite, b.isFinite, c.isFinite,
              a > 0, b > 0, c > 0,
              cosalpha.isFinite, cosbeta.isFinite, cosgamma.isFinite,
              abs(cosalpha) <= 1.0 + 1e-10,
              abs(cosbeta) <= 1.0 + 1e-10,
              abs(cosgamma) <= 1.0 + 1e-10 else {
            return nil
        }
        // Floating-point dot products can exceed the mathematical [-1, 1]
        // interval by a few ulps. Clamp only after the validation above.
        let safeCosbeta = min(1.0, max(-1.0, cosbeta))

        // Use authoritative spg_db mapping for centering. The detected
        // centering from spglib can change under rotation (e.g., cubic F
        // detected as orthorhombic P), but the space-group number is
        // rotation-invariant and spg_db gives the correct conventional
        // centering for the standardized cell.
        let effectiveCentering = centeringFromSpg(spaceGroup) ?? centering

        switch spaceGroup {
        case 1...2:
            // Triclinic: aP2 (all-obtuse reciprocal) or aP3 (all-acute reciprocal)
            guard let result = aPVariant(standardizedLattice: standardizedLattice) else { return nil }
            return (result.variant, result.realCellFinal)
        case 3...15:
            return (monoclinic(spaceGroup: spaceGroup, a: a, b: b, c: c,
                               cosbeta: safeCosbeta, centering: effectiveCentering), nil)
        case 16...74:
            return (orthorhombic(spaceGroup: spaceGroup, a: a, b: b, c: c, centering: effectiveCentering), nil)
        case 75...142:
            return (tetragonal(spaceGroup: spaceGroup, a: a, c: c, centering: effectiveCentering), nil)
        case 143...167:
            return (trigonal(spaceGroup: spaceGroup, a: a, c: c, centering: effectiveCentering), nil)
        case 168...194:
            return ("hP2", nil) // hP has no metric variants in the hexagonal case
        case 195...230:
            return (cubic(spaceGroup: spaceGroup, centering: effectiveCentering), nil)
        default:
            return nil
        }
    }

    private static func cubic(spaceGroup: Int, centering: CrystalCentering) -> String {
        switch centering {
        case .face:
            return (spaceGroup >= 195 && spaceGroup <= 206) ? "cF1" : "cF2"
        case .body:
            return "cI1"
        default:
            return (spaceGroup >= 195 && spaceGroup <= 206) ? "cP1" : "cP2"
        }
    }

    private static func tetragonal(spaceGroup: Int, a: Double, c: Double, centering: CrystalCentering) -> String {
        if centering == .body {
            return c <= a ? "tI1" : "tI2"
        }
        // tP: no c/a split
        return "tP1"
    }

    private static func trigonal(spaceGroup: Int, a: Double, c: Double, centering: CrystalCentering) -> String {
        // Use spg_db centering to distinguish hR (rhombohedral) from hP
        // (hexagonal). This is rotation-invariant, unlike detected centering.
        if centering == .rhombohedral {
            // hR: compare sqrt(3)*a vs sqrt(2)*c
            return sqrt(3.0) * a <= sqrt(2.0) * c ? "hR1" : "hR2"
        }
        // hP: specific space groups (hexagonal, not rhombohedral).
        // SeekPath includes rhombohedral SGs standardized to hexagonal
        // setting (146, 148, 160, 161) in the hP1 list; spg_db marks
        // these as R so they are handled above. The remaining hP1 SGs:
        let hP1Groups: Set<Int> = [143, 144, 145, 147, 149, 151, 153, 157, 159, 162, 163]
        return hP1Groups.contains(spaceGroup) ? "hP1" : "hP2"
    }

    private static func orthorhombic(spaceGroup: Int, a: Double, b: Double, c: Double, centering: CrystalCentering) -> String {
        switch centering {
        case .primitive:
            return "oP1"
        case .face:
            let invA2 = 1.0 / (a * a)
            let invB2 = 1.0 / (b * b)
            let invC2 = 1.0 / (c * c)
            if invA2 > invB2 + invC2 { return "oF1" }
            if invC2 > invA2 + invB2 { return "oF2" }
            return "oF3"
        case .body:
            // SeekPath sorts [(c, 1), (b, 3), (a, 2)] descending; the second
            // element is the variant index: c largest -> oI1, a largest -> oI2,
            // b largest -> oI3. Preserve Python's complete tuple ordering at
            // an exact metric tie: a partial `length > length` comparator is
            // not deterministic and may select oI1 instead of SeekPath's oI3.
            let sorted = [(c, 1), (b, 3), (a, 2)].sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                return lhs.1 > rhs.1
            }
            return "oI\(sorted[0].1)"
        case .baseC:
            return a <= b ? "oC1" : "oC2"
        case .baseA, .baseB:
            // oA: compare b and c
            return b <= c ? "oA1" : "oA2"
        default:
            return "oP1"
        }
    }

    private static func monoclinic(spaceGroup: Int, a: Double, b: Double, c: Double,
                                   cosbeta: Double, centering: CrystalCentering) -> String {
        switch centering {
        case .primitive:
            return "mP1"
        case .baseC, .baseA, .baseB:
            let sinbeta = sqrt(1.0 - cosbeta * cosbeta)
            if b < a * sinbeta {
                return "mC1"
            } else {
                let expr = -a * cosbeta / c + a * a * (1.0 - cosbeta * cosbeta) / (b * b)
                return expr <= 1.0 ? "mC2" : "mC3"
            }
        default:
            return "mP1"
        }
    }

    /// Full aP variant selection following SeekPath __init__.py.
    /// Computes the reciprocal cell, Niggli-reduces it, applies M2/M3 transforms
    /// to select between aP2 (all-obtuse reciprocal) and aP3 (all-acute reciprocal).
    /// Returns nil if the reduction fails (non-finite or singular).
    /// On success, also returns the final real-space cell (real_cell_final) whose
    /// reciprocal basis is the correct frame for the aP point coordinates.
    private static func aPVariant(standardizedLattice: CrystalSymmetryMatrix) -> (variant: String, realCellFinal: [Double])? {
        // Compute reciprocal cell rows from the standardized direct lattice.
        guard let recipRows = reciprocalCellRows(standardizedLattice) else { return nil }

        // Niggli-reduce the reciprocal cell. The C wrapper modifies the lattice
        // in place; we copy first so the original is preserved.
        var reduced = recipRows
        let status = reduced.withUnsafeMutableBufferPointer { buf in
            molenv_spglib_niggli_reduce(buf.baseAddress, 1e-5)
        }
        guard status == MOLENV_SPGLIB_OK else { return nil }
        guard finiteMatrix(reduced) else { return nil }

        // Compute cell parameters of the reduced reciprocal cell.
        let params = cellParams(reduced)
        guard validCellParams(params) else { return nil }
        let conditions = [
            abs(params.b * params.c * params.cosalpha),
            abs(params.c * params.a * params.cosbeta),
            abs(params.a * params.b * params.cosgamma),
        ]
        // M2: permute axes so that |kb*kc*cos(alpha)| is smallest.
        let m2Matrices: [[Double]] = [
            [0, 0, 1, 1, 0, 0, 0, 1, 0],
            [0, 1, 0, 0, 0, 1, 1, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0, 1],
        ]
        let smallestIdx = conditions.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
        let M2 = m2Matrices[smallestIdx]
        // Apply M2: real_cell3 = real_cell2^T * M2 (row-vector convention)
        guard let realCell2 = directCellFromReciprocalRows(reduced) else { return nil }
        let realCell3 = matTransposeMultiply(realCell2, M2)
        guard finiteMatrix(realCell3) else { return nil }
        let recip3 = reciprocalCellRowsDirect(realCell3)
        guard let recip3 else { return nil }
        let p3 = cellParams(recip3)
        guard validCellParams(p3) else { return nil }

        // M3: make all-acute or all-obtuse.
        let ca = p3.cosalpha, cb = p3.cosbeta, cc = p3.cosgamma
        let M3: [Double]
        if ca > 0 && cb > 0 && cc > 0 {
            M3 = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        } else if ca <= 0 && cb <= 0 && cc <= 0 {
            M3 = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        } else if ca > 0 && cb <= 0 && cc <= 0 {
            M3 = [1, 0, 0, 0, -1, 0, 0, 0, -1]
        } else if ca <= 0 && cb > 0 && cc > 0 {
            M3 = [1, 0, 0, 0, -1, 0, 0, 0, -1]
        } else if ca <= 0 && cb > 0 && cc <= 0 {
            M3 = [-1, 0, 0, 0, 1, 0, 0, 0, -1]
        } else if ca > 0 && cb <= 0 && cc > 0 {
            M3 = [-1, 0, 0, 0, 1, 0, 0, 0, -1]
        } else if ca <= 0 && cb <= 0 && cc > 0 {
            M3 = [-1, 0, 0, 0, -1, 0, 0, 0, 1]
        } else if ca > 0 && cb > 0 && cc <= 0 {
            M3 = [-1, 0, 0, 0, -1, 0, 0, 0, 1]
        } else {
            return nil
        }

        let realCellFinal = matTransposeMultiply(realCell3, M3)
        guard finiteMatrix(realCellFinal) else { return nil }
        let recipFinal = reciprocalCellRowsDirect(realCellFinal)
        guard let recipFinal else { return nil }
        let pf = cellParams(recipFinal)
        guard validCellParams(pf) else { return nil }

        if pf.cosalpha <= 0 && pf.cosbeta <= 0 && pf.cosgamma <= 0 {
            return ("aP2", realCellFinal)
        } else if pf.cosalpha >= 0 && pf.cosbeta >= 0 && pf.cosgamma >= 0 {
            return ("aP3", realCellFinal)
        }
        return nil
    }
}

// MARK: - aP helper functions

/// Scale-relative singularity threshold for a 3x3 row-major lattice. Uses the
/// largest row magnitude so huge real cells (tiny reciprocal) and tiny cells (huge
/// reciprocal) are judged by |det|/scale^3, not an absolute cutoff that would
/// false-reject the small-determinant case. Returns 0 when the matrix has no scale
/// (all-zero rows), which correctly fails the subsequent `abs(det) > threshold`
/// guard as singular.
func singularityThreshold(_ rows: [Double]) -> Double {
    // Largest row magnitude (manual norm: file-local to avoid depending on a
    // `length` overload that is private to other files).
    var scale = 0.0
    for i in 0..<3 {
        let x = rows[i * 3], y = rows[i * 3 + 1], z = rows[i * 3 + 2]
        scale = max(scale, sqrt(x * x + y * y + z * z))
    }
    return 1e-12 * scale * scale * scale
}

/// Compute reciprocal cell rows (2π convention) from a row-vector direct lattice.
func reciprocalCellRows(_ lattice: CrystalSymmetryMatrix) -> [Double]? {
    let rows = [
        lattice[0, 0], lattice[0, 1], lattice[0, 2],
        lattice[1, 0], lattice[1, 1], lattice[1, 2],
        lattice[2, 0], lattice[2, 1], lattice[2, 2],
    ]
    let threshold = singularityThreshold(rows)
    let v = simd_double3x3(rows: (
        SIMD3(rows[0], rows[1], rows[2]),
        SIMD3(rows[3], rows[4], rows[5]),
        SIMD3(rows[6], rows[7], rows[8])
    ))
    let det = v.determinant
    guard det.isFinite, threshold > 0, abs(det) > threshold else { return nil }
    let inv = v.inverse
    let scale = 2.0 * Double.pi
    // Reciprocal rows = columns of 2π * inv, stored as row-major [a*, b*, c*].
    return [
        inv.columns.0.x * scale, inv.columns.0.y * scale, inv.columns.0.z * scale,
        inv.columns.1.x * scale, inv.columns.1.y * scale, inv.columns.1.z * scale,
        inv.columns.2.x * scale, inv.columns.2.y * scale, inv.columns.2.z * scale,
    ]
}

/// Compute direct cell rows from reciprocal cell rows (inverse of reciprocalCellRows).
func directCellFromReciprocalRows(_ recipRows: [Double]) -> [Double]? {
    let threshold = singularityThreshold(recipRows)
    let v = simd_double3x3(rows: (
        SIMD3(recipRows[0], recipRows[1], recipRows[2]),
        SIMD3(recipRows[3], recipRows[4], recipRows[5]),
        SIMD3(recipRows[6], recipRows[7], recipRows[8])
    ))
    let det = v.determinant
    guard det.isFinite, threshold > 0, abs(det) > threshold else { return nil }
    let inv = v.inverse
    let scale = 2.0 * Double.pi
    return [
        inv.columns.0.x * scale, inv.columns.0.y * scale, inv.columns.0.z * scale,
        inv.columns.1.x * scale, inv.columns.1.y * scale, inv.columns.1.z * scale,
        inv.columns.2.x * scale, inv.columns.2.y * scale, inv.columns.2.z * scale,
    ]
}

/// Compute reciprocal cell rows from direct cell rows (non-optional path for known-good data).
func reciprocalCellRowsDirect(_ directRows: [Double]) -> [Double]? {
    // Same scale-relative singularity test as reciprocalCellRows /
    // directCellFromReciprocalRows: this path consumes known-good standardized
    // rows, but an absolute 1e-12 cutoff would still false-reject huge real cells
    // (tiny reciprocal). Normal cells are unaffected (relative == absolute there).
    let threshold = singularityThreshold(directRows)
    let v = simd_double3x3(rows: (
        SIMD3(directRows[0], directRows[1], directRows[2]),
        SIMD3(directRows[3], directRows[4], directRows[5]),
        SIMD3(directRows[6], directRows[7], directRows[8])
    ))
    let det = v.determinant
    guard det.isFinite, threshold > 0, abs(det) > threshold else { return nil }
    let inv = v.inverse
    let scale = 2.0 * Double.pi
    return [
        inv.columns.0.x * scale, inv.columns.0.y * scale, inv.columns.0.z * scale,
        inv.columns.1.x * scale, inv.columns.1.y * scale, inv.columns.1.z * scale,
        inv.columns.2.x * scale, inv.columns.2.y * scale, inv.columns.2.z * scale,
    ]
}

/// Compute cell parameters from a row-vector lattice.
func cellParams(_ rows: [Double]) -> (a: Double, b: Double, c: Double,
                                          cosalpha: Double, cosbeta: Double, cosgamma: Double) {
    let va = SIMD3(rows[0], rows[1], rows[2])
    let vb = SIMD3(rows[3], rows[4], rows[5])
    let vc = SIMD3(rows[6], rows[7], rows[8])
    let a = sqrt(dot(va, va))
    let b = sqrt(dot(vb, vb))
    let c = sqrt(dot(vc, vc))
    // Guard the denominators: a zero-length axis (degenerate cell) would otherwise
    // produce NaN via 0/0. validCellParams rejects non-finite cosines, so a sentinel
    // 0 here cleanly fails validation rather than propagating NaN into a route.
    let cosalpha = (b * c > 0) ? (dot(vb, vc) / (b * c)) : 0
    let cosbeta = (a * c > 0) ? (dot(va, vc) / (a * c)) : 0
    let cosgamma = (a * b > 0) ? (dot(va, vb) / (a * b)) : 0
    return (a, b, c, cosalpha, cosbeta, cosgamma)
}

/// Validate cell parameters before using them in variant conditions. Reduction
/// and matrix inversion should never feed non-finite values into a route; an
/// ambiguous or numerically degenerate triclinic cell is a safe no-path case.
func validCellParams(_ params: (a: Double, b: Double, c: Double,
                                cosalpha: Double, cosbeta: Double, cosgamma: Double)) -> Bool {
    guard params.a.isFinite, params.b.isFinite, params.c.isFinite,
          params.a > 0, params.b > 0, params.c > 0,
          params.cosalpha.isFinite, params.cosbeta.isFinite, params.cosgamma.isFinite else {
        return false
    }
    let tolerance = 1e-10
    return abs(params.cosalpha) <= 1.0 + tolerance &&
           abs(params.cosbeta) <= 1.0 + tolerance &&
           abs(params.cosgamma) <= 1.0 + tolerance
}

/// Check that all 9 values in a row-major 3x3 matrix are finite.
func finiteMatrix(_ m: [Double]) -> Bool {
    guard m.count == 9 else { return false }
    return m.allSatisfy { $0.isFinite }
}

/// Multiply two row-major 3x3 matrices: result = A @ B.
/// Uses the row-vector convention where lattice rows are basis vectors.
func matMultiply(_ a: [Double], _ b: [Double]) -> [Double] {
    var result = Array(repeating: 0.0, count: 9)
    for i in 0..<3 {
        for j in 0..<3 {
            var sum = 0.0
            for k in 0..<3 {
                sum += a[i * 3 + k] * b[k * 3 + j]
            }
            result[i * 3 + j] = sum
        }
    }
    return result
}

/// Invert a row-major 3x3 matrix. Returns nil if singular.
func matInverse(_ m: [Double]) -> [Double]? {
    guard m.count == 9 else { return nil }
    let a = m[0], b = m[1], c = m[2]
    let d = m[3], e = m[4], f = m[5]
    let g = m[6], h = m[7], i = m[8]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    guard det.isFinite, abs(det) > 1e-14 else { return nil }
    let invDet = 1.0 / det
    let inverse = [
        (e * i - f * h) * invDet, (c * h - b * i) * invDet, (b * f - c * e) * invDet,
        (f * g - d * i) * invDet, (a * i - c * g) * invDet, (c * d - a * f) * invDet,
        (d * h - e * g) * invDet, (b * g - a * h) * invDet, (a * e - b * d) * invDet,
    ]
    return finiteMatrix(inverse) ? inverse : nil
}

/// Multiply a row-major 3x3 matrix by the transpose of a row-vector lattice.
/// Result: (M^T * lattice) stored as row-major.
/// This mirrors the SeekPath Python idiom:
///   np.dot(lattice.T, M).T == M.T @ lattice
/// where lattice has rows = basis vectors. The M2/M3 permutation/sign
/// matrices are applied as M.T @ lattice, NOT lattice.T @ M (which would
/// give the wrong permutation for non-symmetric M).
func matTransposeMultiply(_ lattice: [Double], _ m: [Double]) -> [Double] {
    // (M.T @ lattice)[i][j] = sum_k M.T[i][k] * lattice[k][j] = sum_k M[k][i] * lattice[k][j]
    var result = Array(repeating: 0.0, count: 9)
    for i in 0..<3 {
        for j in 0..<3 {
            var sum = 0.0
            for k in 0..<3 {
                sum += m[k * 3 + i] * lattice[k * 3 + j]
            }
            result[i * 3 + j] = sum
        }
    }
    return result
}



// MARK: - Public API

/// A labeled special k-point in the primitive reciprocal fractional basis.
struct HPKOTPath {
    var label: String
    var frac: SIMD3<Float>
}

/// Result of HPKOT path generation: the selected variant, labeled special
/// k-points in the primitive reciprocal fractional basis, the ordered edge
/// list with break indices, and the primitive reciprocal lattice vectors.
struct HPKOTResult {
    /// The selected extended Bravais variant (e.g., "cP1", "aP2").
    let variant: String
    /// Special k-points in the primitive reciprocal fractional basis.
    let points: [HPKOTPath]
    /// Break indices in the edge list.
    let breaks: [Int]
    /// Primitive reciprocal lattice vectors (a*, b*, c*) built from
    /// standardizedLattice (spglib's idealized Cartesian frame). Used for
    /// direct SeekPath oracle comparison.
    let canonicalPrimRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)
    /// Primitive reciprocal lattice vectors (a*, b*, c*) built from
    /// preidealizedBravaisLattice (input Cartesian orientation). This is the
    /// basis mapToInputReciprocal must use so that a physically rotated input
    /// crystal gets a physically rotated k-path.
    let inputOrientedPrimRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)
}

/// Generate the HPKOT canonical high-symmetry k-path for the given symmetry.
/// Returns the path as an ordered list of labeled k-points in the primitive
/// reciprocal fractional basis, plus the break indices.
enum HPKOTGenerator {

    /// Generate the canonical path. Returns nil if the variant is unknown.
    /// The primitive reciprocal basis returned in the result is the correct
    /// frame for interpreting the fractional coordinates: for non-aP lattices
    /// it is the reciprocal of the HPKOT primitive lattice constructed from
    /// the standardized conventional lattice using the P matrix from
    /// seekpath/hpkot/spg_mapping.py; for aP lattices it is the reciprocal
    /// of the M2/M3-reduced real cell (real_cell_final).
    static func generate(for symmetry: CrystalSymmetry) -> HPKOTResult? {
        let params = conventionalParams(symmetry)
        guard let selection = VariantSelect.select(
            spaceGroup: symmetry.spaceGroupNumber,
            a: params.a, b: params.b, c: params.c,
            cosalpha: params.cosalpha, cosbeta: params.cosbeta, cosgamma: params.cosgamma,
            centering: symmetry.bravaisLattice.centering,
            hallNumber: symmetry.hallNumber,
            standardizedLattice: symmetry.standardizedLattice,
            transformation: symmetry.inputToPreidealizedBravaisFractional
        ) else {
            return nil
        }
        let variant = selection.variant
        let realCellFinal = selection.realCellFinal

        guard let data = SeekPathData.data(for: variant) else { return nil }

        // Evaluate k-parameters
        var kparam: [String: Double] = [:]
        for def in data.kParams {
            guard let value = KParamEval.evalCompound(
                def.expression, params.a, params.b, params.c,
                params.cosalpha, params.cosbeta, params.cosgamma, kparam
            ), value.isFinite else { return nil }
            kparam[def.name] = value
        }
        let kparamExtended = KParamEval.extend(kparam)

        // Compute point coordinates
        var pointCoords: [String: SIMD3<Double>] = [:]
        for def in data.points {
            guard let x = KParamEval.evalSimple(def.coordExprs.0, kparamExtended),
                  let y = KParamEval.evalSimple(def.coordExprs.1, kparamExtended),
                  let z = KParamEval.evalSimple(def.coordExprs.2, kparamExtended),
                  x.isFinite, y.isFinite, z.isFinite,
                  Float(x).isFinite, Float(y).isFinite, Float(z).isFinite else {
                return nil
            }
            pointCoords[def.label] = SIMD3<Double>(x, y, z)
        }

        // Build ordered node list and break indices from edge list
        var nodes: [String] = []
        var breaks: [Int] = []
        for (i, edge) in data.edges.enumerated() {
            if i == 0 {
                nodes.append(edge.0)
                nodes.append(edge.1)
            } else {
                // nodes.last is guaranteed non-nil here (i > 0 implies the
                // i == 0 branch already appended two elements), but use
                // optional binding to avoid a force unwrap.
                if let last = nodes.last, edge.0 == last {
                    nodes.append(edge.1)
                } else {
                    breaks.append(nodes.count - 1)
                    nodes.append(edge.0)
                    nodes.append(edge.1)
                }
            }
        }

        // Convert to HPKOTPath structs
        let pathPoints = nodes.compactMap { label -> HPKOTPath? in
            guard let coords = pointCoords[label] else { return nil }
            return HPKOTPath(label: label, frac: SIMD3<Float>(Float(coords.x), Float(coords.y), Float(coords.z)))
        }

        guard pathPoints.count == nodes.count else { return nil }

        // Compute the canonical primitive reciprocal basis from the
        // standardized lattice (spglib's idealized Cartesian frame). For aP
        // lattices this is the reciprocal of real_cell_final (the
        // M2/M3-reduced cell); for all other lattices it is the reciprocal of
        // the HPKOT primitive lattice constructed from the standardized
        // conventional lattice using the P matrix: prim_lattice = P.T @
        // conv_lattice. This follows seekpath/hpkot/spg_mapping.py
        // get_primitive and differs from spglib's detectedPrimitiveLattice
        // convention for centered cells.
        let canonicalPrimRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)
        if let realCellFinal = realCellFinal {
            // aP: primitive lattice is real_cell_final itself (P = I)
            guard let reciprocal = reciprocalVectorsOfRows(realCellFinal) else { return nil }
            canonicalPrimRecip = reciprocal
        } else {
            // Non-aP: construct primitive lattice from standardized
            // conventional lattice using the HPKOT P matrix.
            let bravaisLattice = VariantSelect.bravaisLatticeString(for: variant)
            guard let pMat = VariantSelect.pMatrix(for: bravaisLattice) else { return nil }
            let stdLatticeValues = symmetry.standardizedLattice.values
            let primLattice = matTransposeMultiply(stdLatticeValues, pMat)
            guard finiteMatrix(primLattice) else { return nil }
            guard let reciprocal = reciprocalVectorsOfRows(primLattice) else { return nil }
            canonicalPrimRecip = reciprocal
        }

        // Compute the input-oriented primitive reciprocal basis from
        // preidealizedBravaisLattice (input Cartesian orientation). This is
        // the basis mapToInputReciprocal must use so that a physically
        // rotated input crystal gets a physically rotated k-path.
        let inputOrientedPrimRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)
        if let realCellFinal = realCellFinal {
            // aP: derive Q from realCellFinal = Q @ standardizedLattice,
            // validate Q, then use Q @ preidealizedBravaisLattice.
            let stdValues = symmetry.standardizedLattice.values
            guard let stdInv = matInverse(stdValues) else { return nil }
            let qMat = matMultiply(realCellFinal, stdInv)
            guard finiteMatrix(qMat) else { return nil }
            // Validate: Q @ standardizedLattice should reproduce realCellFinal
            let check = matMultiply(qMat, stdValues)
            guard finiteMatrix(check) else { return nil }
            let preidealizedValues = symmetry.preidealizedBravaisLattice.values
            let inputOrientedPrimLattice = matMultiply(qMat, preidealizedValues)
            guard finiteMatrix(inputOrientedPrimLattice) else { return nil }
            guard let reciprocal = reciprocalVectorsOfRows(inputOrientedPrimLattice) else { return nil }
            inputOrientedPrimRecip = reciprocal
        } else {
            // Non-aP: construct primitive lattice from preidealizedBravaisLattice
            // using the HPKOT P matrix: P.T @ preidealizedBravaisLattice.
            let bravaisLattice = VariantSelect.bravaisLatticeString(for: variant)
            guard let pMat = VariantSelect.pMatrix(for: bravaisLattice) else { return nil }
            let preidealizedValues = symmetry.preidealizedBravaisLattice.values
            let inputOrientedPrimLattice = matTransposeMultiply(preidealizedValues, pMat)
            guard finiteMatrix(inputOrientedPrimLattice) else { return nil }
            guard let reciprocal = reciprocalVectorsOfRows(inputOrientedPrimLattice) else { return nil }
            inputOrientedPrimRecip = reciprocal
        }

        return HPKOTResult(variant: variant, points: pathPoints, breaks: breaks,
                           canonicalPrimRecip: canonicalPrimRecip,
                           inputOrientedPrimRecip: inputOrientedPrimRecip)
    }

    /// Map a path from the primitive reciprocal fractional basis to the input-cell
    /// reciprocal fractional basis. Goes through Cartesian to avoid the
    /// primitive/conventional fractional transform ambiguity:
    ///   primitive reciprocal frac -> Cartesian -> input reciprocal frac.
    /// Uses inputOrientedPrimRecip (built from preidealizedBravaisLattice in
    /// input Cartesian orientation) so that a physically rotated input crystal
    /// gets a physically rotated k-path.
    static func mapToInputReciprocal(_ path: [HPKOTPath], breaks: [Int],
                                     inputOrientedPrimRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>),
                                     inputCell: Cell) -> (points: [HPKOTPath], breaks: [Int]) {

        // Compute the input reciprocal lattice vectors.
        let inputRecip = inputCell.reciprocalVectors
        let inputBasis = simd_float3x3(columns: (inputRecip.a, inputRecip.b, inputRecip.c))
        guard inputBasis.determinant.isFinite, abs(inputBasis.determinant) > 1e-12 else {
            return (path, breaks)
        }
        let inputInv = inputBasis.inverse

        let primA = inputOrientedPrimRecip.a
        let primB = inputOrientedPrimRecip.b
        let primC = inputOrientedPrimRecip.c
        let mapped = path.map { hp -> HPKOTPath in
            let primFrac = SIMD3<Double>(Double(hp.frac.x), Double(hp.frac.y), Double(hp.frac.z))
            // Input-oriented primitive reciprocal fractional -> Cartesian
            let cart = primA * Float(primFrac.x) + primB * Float(primFrac.y) + primC * Float(primFrac.z)
            // Cartesian -> input reciprocal fractional
            let f = inputInv * cart
            return HPKOTPath(label: hp.label, frac: SIMD3<Float>(f.x, f.y, f.z))
        }

        return (points: mapped, breaks: breaks)
    }

    /// Compute the conventional cell parameters from the standardized lattice.
    static func conventionalParams(_ symmetry: CrystalSymmetry) -> (a: Double, b: Double, c: Double, cosalpha: Double, cosbeta: Double, cosgamma: Double) {
        let L = symmetry.standardizedLattice
        let va = SIMD3(L[0, 0], L[0, 1], L[0, 2])
        let vb = SIMD3(L[1, 0], L[1, 1], L[1, 2])
        let vc = SIMD3(L[2, 0], L[2, 1], L[2, 2])
        let a = sqrt(va.x*va.x + va.y*va.y + va.z*va.z)
        let b = sqrt(vb.x*vb.x + vb.y*vb.y + vb.z*vb.z)
        let c = sqrt(vc.x*vc.x + vc.y*vc.y + vc.z*vc.z)
        let cosalpha = dot(vb, vc) / (b * c)
        let cosbeta = dot(va, vc) / (a * c)
        let cosgamma = dot(va, vb) / (a * b)
        return (a, b, c, cosalpha, cosbeta, cosgamma)
    }

    /// Compute the reciprocal lattice vectors (2π convention) of a row-vector
    /// direct lattice given as a flat row-major 9-element array.
    private static func reciprocalVectorsOfRows(_ rows: [Double]) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)? {
        guard rows.count == 9, finiteMatrix(rows) else { return nil }
        let v = simd_double3x3(rows: (
            SIMD3(rows[0], rows[1], rows[2]),
            SIMD3(rows[3], rows[4], rows[5]),
            SIMD3(rows[6], rows[7], rows[8])
        ))
        let det = v.determinant
        guard det.isFinite, abs(det) > 1e-12 else {
            return nil
        }
        let inv = v.inverse
        let scale = 2.0 * Double.pi
        let aVec = inv.columns.0 * scale
        let bVec = inv.columns.1 * scale
        let cVec = inv.columns.2 * scale
        let a = SIMD3<Float>(Float(aVec.x), Float(aVec.y), Float(aVec.z))
        let b = SIMD3<Float>(Float(bVec.x), Float(bVec.y), Float(bVec.z))
        let c = SIMD3<Float>(Float(cVec.x), Float(cVec.y), Float(cVec.z))
        guard a.x.isFinite, a.y.isFinite, a.z.isFinite,
              b.x.isFinite, b.y.isFinite, b.z.isFinite,
              c.x.isFinite, c.y.isFinite, c.z.isFinite else {
            return nil
        }
        return (a: a, b: b, c: c)
    }

    /// Compute the reciprocal lattice vectors (2π convention) of a row-vector
    /// direct lattice matrix. Returns (a*, b*, c*) as a tuple.
    private static func reciprocalVectorsOf(_ lattice: CrystalSymmetryMatrix) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let v = simd_double3x3(rows: (
            SIMD3<Double>(lattice[0, 0], lattice[0, 1], lattice[0, 2]),
            SIMD3<Double>(lattice[1, 0], lattice[1, 1], lattice[1, 2]),
            SIMD3<Double>(lattice[2, 0], lattice[2, 1], lattice[2, 2])
        ))
        let det = v.determinant
        guard det.isFinite, abs(det) > 1e-12 else {
            return (.zero, .zero, .zero)
        }
        let inv = v.inverse
        let scale = 2.0 * Double.pi
        let aVec = inv.columns.0 * scale
        let bVec = inv.columns.1 * scale
        let cVec = inv.columns.2 * scale
        return (a: SIMD3<Float>(Float(aVec.x), Float(aVec.y), Float(aVec.z)),
                b: SIMD3<Float>(Float(bVec.x), Float(bVec.y), Float(bVec.z)),
                c: SIMD3<Float>(Float(cVec.x), Float(cVec.y), Float(cVec.z)))
    }
}

// MARK: - simd_double3x3 row-vector initializer

extension simd_double3x3 {
    /// Initialize from row vectors.
    init(rows: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)) {
        self.init(columns: (SIMD3(rows.0.x, rows.1.x, rows.2.x),
                           SIMD3(rows.0.y, rows.1.y, rows.2.y),
                           SIMD3(rows.0.z, rows.1.z, rows.2.z)))
    }
}

// MARK: - CrystalSymmetryMatrix reciprocal extension

extension CrystalSymmetryMatrix {
    /// Reciprocal lattice vectors (2π convention) of this direct lattice matrix.
    /// The lattice matrix uses rows as basis vectors, so the reciprocal vectors
    /// are the columns of (2π * inverse).
    var reciprocalVectors: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let v = simd_double3x3(rows: (
            SIMD3(self[0, 0], self[0, 1], self[0, 2]),
            SIMD3(self[1, 0], self[1, 1], self[1, 2]),
            SIMD3(self[2, 0], self[2, 1], self[2, 2])
        ))
        let det = v.determinant
        guard det.isFinite, abs(det) > 1e-12 else {
            return (.zero, .zero, .zero)
        }
        let inv = v.inverse
        let scale = 2.0 * Double.pi
        func toFloat(_ d: SIMD3<Double>) -> SIMD3<Float> {
            SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
        }
        return (a: toFloat(inv.columns.0 * scale),
                b: toFloat(inv.columns.1 * scale),
                c: toFloat(inv.columns.2 * scale))
    }
}
