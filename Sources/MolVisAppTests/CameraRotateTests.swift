import XCTest
import Metal
import simd
@testable import MolVisApp
private enum Thrown: Error { case msg(String) }

// Mirror the EXACT gesture mutator from MetalView.mouseDragged
func applyDrag(_ cam: inout Camera, dx: Float, dy: Float) {
    let rotX = simd_quatf(angle: dy * 0.01, axis: SIMD3(1,0,0))
    let rotY = simd_quatf(angle: dx * 0.01, axis: SIMD3(0,1,0))
    cam.rotation = rotY * rotX * cam.rotation
}

final class CameraRotateTests: XCTestCase {
    // Replicate MainWindowController.setNeedsRender's render trigger and render
    // the SAME scene with two cameras, projecting an atom to pixels, and
    // confirm it orbits (constant distance from image center).
    func testDragRotatesNotTranslates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.msg("no GPU") }
        let w = 100, h = 100
        func render(_ cam: Camera) -> [UInt8] {
            let r = try! Renderer(device: device)
            var s = Scene()
            s.atoms = [Atom(coord: SIMD3(0,0,0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1.2,0,0), atomicNumber: 1, label: "H")]
            r.scene = s
            r.currentCamera = cam
            let desc = MTLTextureDescriptor()
            desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
            desc.usage = [.renderTarget,.shaderRead]; desc.storageMode = .shared
            let tex = device.makeTexture(descriptor: desc)!
            let cb = device.makeCommandQueue()!.makeCommandBuffer()!
            r.encode(to: cb, target: tex, viewport: MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1), camera: cam)
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating:0,count:w*h*4)
            tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
            return px
        }
        // centroid-centered camera like applyCameraForNewSceneIfNeeded sets
        func makeCam(_ rot: simd_quatf) -> Camera {
            var c = Camera()
            c.center = SIMD3(0.6,0,0); c.distance = 6; c.rotation = rot
            return c
        }
        let pxBefore = render(makeCam(simd_quatf(ix:0,iy:0,iz:0,r:1)))
        var cam90 = makeCam(simd_quatf(ix:0,iy:0,iz:0,r:1))
        applyDrag(&cam90, dx: 60, dy: 0)   // a rightward drag
        let pxAfter = render(cam90)

        // centroid (unweighted avg) of lit pixels, before vs after
        func centroid(_ px:[UInt8]) -> (Float,Float,Int) {
            var sx=0,sy=0,n=0
            for y in 0..<h { for x in 0..<w {
                let i = (y*w+x)*4
                if px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { sx+=x; sy+=y; n+=1 }
            } }
            guard n>0 else { return (0,0,0) }
            return (Float(sx)/Float(n), Float(sy)/Float(n), n)
        }
        let (cx0,cy0,n0) = centroid(pxBefore)
        let (cx1,cy1,n1) = centroid(pxAfter)
        // image center
        let ic = (Float(w)/2, Float(h)/2)
        let d0 = (cx0-ic.0)*(cx0-ic.0)+(cy0-ic.1)*(cy0-ic.1)
        let d1 = (cx1-ic.0)*(cx1-ic.0)+(cy1-ic.1)*(cy1-ic.1)
        let litMoved = n0>0 && n1>10
        let shifted = (cx1-cx0)*(cx1-cx0)+(cy1-cy0)*(cy1-cy0)
        print("[rot] before centroid=(\(cx0),\(cy0)) n=\(n0)  after=(\(cx1),\(cy1)) n=\(n1)")
        print("[rot] distFromCenter before=\(d0) after=\(d1)  centroid shift=\(shifted)")
        XCTAssertTrue(litMoved, "nothing rendered")
        XCTAssertLessThan(abs(d1-d0), d0*0.5 + 4, "orbital rotation must keep the structure at roughly constant distance from center, not translate it")
    }
}
