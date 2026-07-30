import XCTest
import simd
@testable import MolVisApp

final class BZFramingTests: XCTestCase {
    func testOrthographicFitUsesViewportAspect() {
        let (bz, presentation) = makePresentation()
        let current = Camera(distance: 14, perspective: false)

        let wide = presentation.framedCamera(bz: bz, current: current,
                                              viewport: SIMD2<Float>(1600, 600))
        let tall = presentation.framedCamera(bz: bz, current: current,
                                              viewport: SIMD2<Float>(600, 1600))

        XCTAssertNotNil(wide)
        XCTAssertNotNil(tall)
        XCTAssertGreaterThan(tall!.distance, wide!.distance)
        assertProjectedVertices(in: bz, presentation: presentation, camera: wide!,
                                viewport: SIMD2<Float>(1600, 600))
        assertProjectedVertices(in: bz, presentation: presentation, camera: tall!,
                                viewport: SIMD2<Float>(600, 1600))
    }

    func testPerspectiveFitHandlesRotatedCamera() {
        let (bz, presentation) = makePresentation()
        let rotation = simd_quatf(angle: 0.73, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        var current = Camera(distance: 9, rotation: rotation, perspective: true)
        current.center = SIMD3<Float>(12, -4, 3)

        let framed = presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(1100, 700), padding: 0.86)
        XCTAssertNotNil(framed)
        assertProjectedVertices(in: bz, presentation: presentation, camera: framed!,
                                viewport: SIMD2<Float>(1100, 700), padding: 0.86)
    }

    func testFramingPreservesCenterProjectionAndRotation() {
        let (bz, presentation) = makePresentation()
        let rotation = simd_quatf(angle: -0.41, axis: simd_normalize(SIMD3<Float>(2, -1, 1)))
        let current = Camera(distance: 27, rotation: rotation, perspective: true)

        let framed = presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(800, 800))

        XCTAssertNotNil(framed)
        XCTAssertEqual(framed!.center, presentation.center)
        XCTAssertEqual(framed!.perspective, current.perspective)
        XCTAssertEqual(framed!.rotation.vector.x, current.rotation.vector.x, accuracy: 1e-6)
        XCTAssertEqual(framed!.rotation.vector.y, current.rotation.vector.y, accuracy: 1e-6)
        XCTAssertEqual(framed!.rotation.vector.z, current.rotation.vector.z, accuracy: 1e-6)
        XCTAssertEqual(framed!.rotation.vector.w, current.rotation.vector.w, accuracy: 1e-6)
        XCTAssertNotEqual(framed!.distance, current.distance)
    }

    func testInvalidInputsReturnNil() {
        let (bz, presentation) = makePresentation()
        let current = Camera()

        let empty = BrillouinZone(faces: [], normals: [], specialPoints: [],
                                  reciprocal: (SIMD3<Float>(1, 0, 0),
                                               SIMD3<Float>(0, 1, 0),
                                               SIMD3<Float>(0, 0, 1)))
        let line = BrillouinZone(faces: [[SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                                           SIMD3<Float>(2, 0, 0)]],
                                 normals: [], specialPoints: [],
                                 reciprocal: (SIMD3<Float>(1, 0, 0),
                                               SIMD3<Float>(0, 1, 0),
                                               SIMD3<Float>(0, 0, 1)))
        let nonfinite = BrillouinZone(faces: [[SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                                                SIMD3<Float>(0, 1, 0),
                                                SIMD3<Float>(0, 0, Float.nan)]],
                                      normals: [], specialPoints: [],
                                      reciprocal: (SIMD3<Float>(1, 0, 0),
                                                   SIMD3<Float>(0, 1, 0),
                                                   SIMD3<Float>(0, 0, 1)))
        var badQuaternion = current
        badQuaternion.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 0)
        var badDistance = current
        badDistance.distance = .infinity

        XCTAssertNil(presentation.framedCamera(bz: empty, current: current,
                                                viewport: SIMD2<Float>(800, 600)))
        XCTAssertNil(presentation.framedCamera(bz: line, current: current,
                                                viewport: SIMD2<Float>(800, 600)))
        XCTAssertNil(presentation.framedCamera(bz: nonfinite, current: current,
                                                viewport: SIMD2<Float>(800, 600)))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: badQuaternion,
                                                viewport: SIMD2<Float>(800, 600)))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: badDistance,
                                                viewport: SIMD2<Float>(800, 600)))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(0, 600)))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(800, .nan)))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(800, 600), padding: 0))
        XCTAssertNil(presentation.framedCamera(bz: bz, current: current,
                                                viewport: SIMD2<Float>(800, 600), padding: .infinity))

        let tooDeep = BrillouinZone(
            faces: bz.faces.map { $0.map { $0 * 1_000 } },
            normals: bz.normals,
            specialPoints: bz.specialPoints,
            reciprocal: bz.reciprocal
        )
        var perspective = current
        perspective.perspective = true
        XCTAssertNil(presentation.framedCamera(bz: tooDeep, current: perspective,
                                                viewport: SIMD2<Float>(800, 600)))

        let zeroScalePresentation = BZPresentation(bz: empty, scene: Scene())
        XCTAssertNil(zeroScalePresentation.framedCamera(bz: bz, current: current,
                                                        viewport: SIMD2<Float>(800, 600)))
    }

    func testProjectedVerticesStayInsidePaddedNDCAndDepthRange() {
        let (bz, presentation) = makePresentation()
        let current = Camera(distance: 8,
                             rotation: simd_quatf(angle: 0.5,
                                                  axis: simd_normalize(SIMD3<Float>(-1, 3, 2))),
                             perspective: true)
        let viewport = SIMD2<Float>(900, 500)
        let padding: Float = 0.82
        guard let framed = presentation.framedCamera(bz: bz, current: current,
                                                      viewport: viewport, padding: padding) else {
            return XCTFail("valid BZ should be frameable")
        }

        let view = framed.viewMatrix()
        let projection = framed.projectionMatrix(aspect: viewport.x / viewport.y)
        for face in bz.faces {
            for cartesian in face {
                let world = presentation.world(cartesian: cartesian)
                let clip = projection * view * SIMD4<Float>(world.x, world.y, world.z, 1)
                XCTAssertTrue(clip.w.isFinite)
                XCTAssertGreaterThan(clip.w, 0)
                let ndc = clip / clip.w
                XCTAssertLessThanOrEqual(abs(ndc.x), padding + 1e-5)
                XCTAssertLessThanOrEqual(abs(ndc.y), padding + 1e-5)
                XCTAssertGreaterThanOrEqual(ndc.z, 0)
                XCTAssertLessThanOrEqual(ndc.z, 1)
            }
        }
    }

    func testFramingRemainsFiniteForRepresentableLargeReciprocalGeometry() {
        let (unitBZ, _) = makePresentation()
        let factor = Float.greatestFiniteMagnitude * 0.25
        let bz = BrillouinZone(
            faces: unitBZ.faces.map { $0.map { $0 * factor } },
            normals: unitBZ.normals,
            specialPoints: unitBZ.specialPoints,
            reciprocal: (unitBZ.reciprocal.a * factor,
                         unitBZ.reciprocal.b * factor,
                         unitBZ.reciprocal.c * factor))
        let presentation = BZPresentation(bz: bz, scene: Scene())

        XCTAssertTrue(presentation.inv.isFinite)
        XCTAssertGreaterThan(presentation.inv, 0)
        for face in bz.faces {
            for vertex in face {
                XCTAssertTrue(presentation.world(cartesian: vertex).isFinite)
            }
        }
        XCTAssertNotNil(presentation.framedCamera(bz: bz,
                                                  current: Camera(distance: 14, perspective: false),
                                                  viewport: SIMD2<Float>(800, 600)))
    }

    private func makePresentation() -> (BrillouinZone, BZPresentation) {
        let v: [SIMD3<Float>] = [
            SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
            SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)
        ]
        let faces = [[v[0], v[3], v[2], v[1]], [v[4], v[5], v[6], v[7]],
                     [v[0], v[1], v[5], v[4]], [v[3], v[7], v[6], v[2]],
                     [v[0], v[4], v[7], v[3]], [v[1], v[2], v[6], v[5]]]
        let bz = BrillouinZone(faces: faces, normals: [], specialPoints: [],
                               reciprocal: (SIMD3<Float>(1, 0, 0),
                                            SIMD3<Float>(0, 1, 0),
                                            SIMD3<Float>(0, 0, 1)))
        var scene = Scene()
        scene.atoms = [Atom(coord: SIMD3<Float>(-20, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3<Float>(20, 0, 0), atomicNumber: 6, label: "C")]
        return (bz, BZPresentation(bz: bz, scene: scene))
    }

    private func assertProjectedVertices(in bz: BrillouinZone,
                                          presentation: BZPresentation,
                                          camera: Camera,
                                          viewport: SIMD2<Float>,
                                          padding: Float = 0.9,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        let view = camera.viewMatrix()
        let projection = camera.projectionMatrix(aspect: viewport.x / viewport.y)
        for face in bz.faces {
            for cartesian in face {
                let world = presentation.world(cartesian: cartesian)
                let clip = projection * view * SIMD4<Float>(world.x, world.y, world.z, 1)
                XCTAssertTrue(clip.w.isFinite, file: file, line: line)
                XCTAssertGreaterThan(clip.w, 0, file: file, line: line)
                let ndc = clip / clip.w
                XCTAssertLessThanOrEqual(abs(ndc.x), padding + 1e-5, file: file, line: line)
                XCTAssertLessThanOrEqual(abs(ndc.y), padding + 1e-5, file: file, line: line)
                XCTAssertGreaterThanOrEqual(ndc.z, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(ndc.z, 1, file: file, line: line)
            }
        }
    }
}
