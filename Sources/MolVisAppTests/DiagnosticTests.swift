import XCTest
import simd
@testable import MolVisApp

final class BondCorrectnessTests: XCTestCase {
    private func fixture(_ name: String) throws -> Scene {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/\(name)")))
    }

    // Issue 3 regression: each bond cylinder must connect its two atoms.
    func testBondsConnectAtoms() throws {
        let s = try fixture("h2o.xyz")
        XCTAssertEqual(s.atoms.count, 3)
        XCTAssertGreaterThanOrEqual(s.bonds.count, 2)
        let atoms = s.atoms
        for b in s.bonds {
            let a = atoms[b.i].coord, b2 = atoms[b.j].coord
            let dir = b2 - a
            let len = length(dir)
            let mid = (a + b2) * 0.5
            let model = float4x4(translation: mid)
                * .rotation(fromYTo: dir / len)
                * float4x4(scale: SIMD3<Float>(0.10, len, 0.10))
            // translation column must equal the midpoint
            XCTAssertEqual(model.columns.3.x, mid.x, accuracy: 1e-3)
            XCTAssertEqual(model.columns.3.y, mid.y, accuracy: 1e-3)
            XCTAssertEqual(model.columns.3.z, mid.z, accuracy: 1e-3)
            // the cylinder axis after the model must parallel the bond direction
            let top = (model * SIMD4<Float>(0, 0.5, 0, 1)).xyz
            let bot = (model * SIMD4<Float>(0, -0.5, 0, 1)).xyz
            let axis = top - bot
            let axisN = axis / length(axis)
            let dirN = dir / len
            XCTAssertEqual(axisN.x, dirN.x, accuracy: 1e-3)
            XCTAssertEqual(axisN.y, dirN.y, accuracy: 1e-3)
            XCTAssertEqual(axisN.z, dirN.z, accuracy: 1e-3)
        }
    }

    // Issue 3 unit: +Y rotates to +X for dir=+X.
    func testRotationFromYTo() {
        let R = float4x4.rotation(fromYTo: normalize(SIMD3<Float>(1, 0, 0)))
        let out = (R * SIMD4<Float>(0, 1, 0, 0)).xyz
        XCTAssertEqual(out.x, 1.0, accuracy: 0.01)
        XCTAssertEqual(out.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(out.z, 0.0, accuracy: 0.01)
    }
}

// Issue 2 investigation: does the gesture path orbit the structure (rotate)
// rather than translate it?
final class GestureTests: XCTestCase {
    // Project a world point to normalized device coords [-1,1] using a camera.
    private func project(_ p: SIMD3<Float>, cam: Camera, aspect: Float) -> SIMD2<Float> {
        let v = cam.viewMatrix() * float4x4(projectionMatrix_holder())
        // (use the real matrices)
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: aspect)
        let clip = proj * view * SIMD4(p.x, p.y, p.z, 1)
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }
    private func projectionMatrix_holder() -> Float { 1 }

    // Replicate MetalView.mouseDragged's rotation update, then confirm an
    // off-axis atom orbits (its projected distance from center stays ~constant).
    func testDragOrbitsNotTranslates() {
        var cam = Camera()
        cam.center = SIMD3(0,0,0)
        cam.distance = 10
        // a sample atom off the rotation axis
        let atom = SIMD3<Float>(1.0, 0.5, 0.2)
        let aspect: Float = 1.0

        let before = project(atom, cam: cam, aspect: aspect)
        let rBefore = SIMD2<Float>(before.x, before.y)

        // simulate a drag: dx=+10px, dy=+5px (one mouseDragged call)
        let dx = Float(10), dy = Float(5)
        let rotX = simd_quatf(angle: dy * 0.01, axis: SIMD3(1,0,0))
        let rotY = simd_quatf(angle: dx * 0.01, axis: SIMD3(0,1,0))
        cam.rotation = rotY * rotX * cam.rotation

        let after = project(atom, cam: cam, aspect: aspect)
        let rAfter = SIMD2<Float>(after.x, after.y)

        let dBefore = simd_length(rBefore)
        let dAfter = simd_length(rAfter)
        let shift = simd_length(rAfter - rBefore)
        print("[gesture] projected radius before=\(dBefore) after=\(dAfter) (should be ~constant); lateral shift=\(shift)")
        // ORBITAL: distance from center preserved; TRANSLATION: it would shift uniformly.
        XCTAssertEqual(dBefore, dAfter, accuracy: 0.05, "drag must preserve projected distance from center (orbit), not translate")
        XCTAssertGreaterThan(shift, 0.001, "drag should move the atom at all")
    }
}
