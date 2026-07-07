import XCTest
import simd
@testable import MolVisApp

/// Reference bond-detection ported EXACTLY from XCrySDen readstrf.c
/// (MakeBonds: cutoff = rcov[i]+rcov[j], rcov[i] = DEF_RCOVF(1.05)*rcovdef[i]).
/// Used to verify the parser's bond set matches XCrySDen's algorithm.
final class BondDetectionTests: XCTestCase {

    // rcovdef table from XCrySDen C/atoms.h (indices 0..MAXNAT=100).
    static let rcovdef: [Float] = [
        0.38, 0.38, 0.38, 1.23, 0.89, 0.91,
        0.77, 0.75, 0.73, 0.71, 0.71,
        1.60, 1.40, 1.25, 1.11, 1.00,
        1.04, 0.99, 0.98, 2.13, 1.74,
        1.60, 1.40, 1.35, 1.40, 1.40,
        1.40, 1.35, 1.35, 1.35, 1.35,
        1.30, 1.25, 1.15, 1.15, 1.14,
        1.12, 2.20, 2.00, 1.85, 1.55,
        1.45, 1.45, 1.35, 1.30, 1.35,
        1.40, 1.60, 1.55, 1.55, 1.41,
        1.45, 1.40, 1.40, 1.31, 2.60,
        2.00, 1.75, 1.55, 1.55, 1.55,
        1.55, 1.55, 1.55, 1.55, 1.55,
        1.55, 1.55, 1.55, 1.55, 1.55,
        1.55, 1.55, 1.45, 1.35, 1.35,
        1.30, 1.35, 1.35, 1.35, 1.50,
        1.90, 1.80, 1.60, 1.55, 1.55,
        1.55, 2.80, 1.44, 1.95, 1.55,
        1.55, 1.55, 1.55, 1.55, 1.55,
        1.55, 1.55, 1.55, 1.55, 1.55
    ]
    static let DEF_RCOVF: Float = 1.05

    /// Replicates XCrySDen MakeBonds: bond exists iff dist < rcov[i]+rcov[j].
    private func xcrysdenBonds(_ loaded: LoadedScene) -> Set<Int> {
        let n = Self.rcovdef.count
        var bonds = Set<Int>()
        for i in 0..<loaded.atoms.count {
            for j in (i+1)..<loaded.atoms.count {
                let zi = loaded.atoms[i].atomicNumber
                let zj = loaded.atoms[j].atomicNumber
                if zi <= 0 || zi >= n || zj <= 0 || zj >= n { continue }
                let ri = Self.DEF_RCOVF * Self.rcovdef[zi]
                let rj = Self.DEF_RCOVF * Self.rcovdef[zj]
                let a = loaded.atoms[i].coord, b = loaded.atoms[j].coord
                let d = simd_length(a - b)
                if d < ri + rj {
                    bonds.insert(i * 100000 + j)
                }
            }
        }
        return bonds
    }

    private func parserBonds(_ loaded: LoadedScene) -> Set<Int> {
        var s = Set<Int>()
        for b in loaded.bonds { s.insert(b.i * 100000 + b.j) }
        return s
    }

    private func fixture(_ name: String) throws -> LoadedScene {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return try Parser.load(dir.appendingPathComponent("Fixtures/\(name)"))
    }

    func testBondSetMatchesXCrysdenReference() throws {
        for name in ["h2o.xyz", "si110.xsf", "si.xyz", "ala.pdb"] {
            let s = try fixture(name)
            let parser = parserBonds(s)
            let ref = xcrysdenBonds(s)
            print("[bonds] \(name): parser=\(parser.count) ref=\(ref.count)")
            for b in ref.sorted() where !parser.contains(b) {
                print("[bonds]   MISSING in parser: \(b/100000)-\(b%100000)")
            }
            for b in parser.sorted() where !ref.contains(b) {
                print("[bonds]   EXTRA in parser:   \(b/100000)-\(b%100000)")
            }
            XCTAssertEqual(parser, ref, "\(name): parser bond set must match XCrySDen's MakeBonds")
        }
    }
}
