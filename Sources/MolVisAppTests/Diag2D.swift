import XCTest
import Metal
@testable import MolVisApp

// Diagnostic: render a known structure in 2D mode and report the on-screen
// bounding box of the projected atoms so we can see why the 2D view is wrong.
final class Diag2D: XCTestCase {
    func test2DAtomBBox() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))

        let r = try Renderer(device: device)
        let w = 200, h = 200
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!

        var s = scene
        s = s.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        s.displayMode = .line2D
        s.background = "#000000"
        r.scene = s
        // Auto-frame as the GUI would after my fix.
        var cam = Camera()
        let (c, rad) = s.boundingSphere()
        cam.center = c
        cam.distance = max(8, rad * 3)
        r.encode(to: cb, target: tex,
                 viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                 camera: cam)
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        // Atoms are colored (blue-ish/green from CPK or yellow if selected);
        // the cell frame is grey (R==G==B, >60). Classify each pixel.
        var aMinX = w, aMinY = h, aMaxX = -1, aMaxY = -1, aCount = 0
        var cMinX = w, cMinY = h, cMaxX = -1, cMaxY = -1, cCount = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            let r = px[i], g = px[i+1], b = px[i+2]
            if r != 0 || g != 0 || b != 0 {
                let isGrey = abs(Int(r)-Int(g))<8 && abs(Int(g)-Int(b))<8 && r > 60
                if isGrey {
                    cCount+=1; if x<cMinX{cMinX=x}; if x>cMaxX{cMaxX=x}
                    if y<cMinY{cMinY=y}; if y>cMaxY{cMaxY=y}
                } else {
                    aCount+=1; if x<aMinX{aMinX=x}; if x>aMaxX{aMaxX=x}
                    if y<aMinY{aMinY=y}; if y>aMaxY{aMaxY=y}
                }
            }
        }}
        func frac(_ x: Int, _ y: Int) -> (Double, Double) { (Double(x)/Double(w), Double(y)/Double(h)) }
        let (ax0,ay0) = frac(aMinX,aMinY), (ax1,ay1) = frac(aMaxX,aMaxY)
        let (cx0,cy0) = frac(cMinX,cMinY), (cx1,cy1) = frac(cMaxX,cMaxY)
        let acx=(ax0+ax1)*0.5, acy=(atoi(ax0,ax1,ay0,ay1))
        func atoi(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->(Double,Double){((a+b)*0.5,(c+d)*0.5)}
        let (accx,accy) = atoi(ax0,ax1,ay0,ay1)
        let (cccx,cccy) = atoi(cx0,cx1,cy0,cy1)
        print(String(format: "[diag2d] ATOMS bbox=(%.3f,%.3f)..(%.3f,%.3f) center=(%.3f,%.3f) n=%d", ax0,ay0,ax1,ay1,accx,accy,aCount))
        print(String(format: "[diag2d] CELL  bbox=(%.3f,%.3f)..(%.3f,%.3f) center=(%.3f,%.3f) n=%d", cx0,cy0,cx1,cy1,cccx,cccy,cCount))
        print(String(format: "[diag2d] camDist=%.2f superCell=\(s.superCell.total)", cam.distance))
        // Atoms and cell frame should be consistent: both centred and overlapping.
        XCTAssertGreaterThan(aCount, 0, "2D atoms should render")
        XCTAssertGreaterThan(cCount, 0, "2D cell frame should render")
        // Atom bbox centre should sit near the cell-frame bbox centre (within 15%).
        XCTAssertEqual(accx, cccx, accuracy: 0.15, "atom/cell horizontal centering mismatch: atoms=\(accx) cell=\(cccx)")
        XCTAssertEqual(accy, cccy, accuracy: 0.15, "atom/cell vertical centering mismatch: atoms=\(accy) cell=\(cccy)")
        // Regression guard: a vertex-stride mismatch in the 2D atom pass blows each
        // tiny quad into a huge corrupted triangle, so atoms sprawl over most of
        // the viewport. A well-formed 2D atom bbox should cover far less than half.
        let atomAreaFrac = Double(aMaxX - aMinX) * Double(aMaxY - aMinY) / Double(w * h)
        XCTAssertLessThan(atomAreaFrac, 0.4, "2D atoms sprawl too far (stride bug?): frac=\(atomAreaFrac) bbox=\(aMinX),\(aMinY)..\(aMaxX),\(aMaxY)")
    }
}
