import Metal
import MetalKit

/// A second MTKViewDelegate that draws the scene flattened along a projection
/// axis. For v1 the simplest correct implementation REUSES the 3D Renderer with
/// an orthographic camera looking down +Z (no rotation). The Renderer's encode
/// also switches to ortho for 2D modes, so this delegate only needs to set up
/// the camera and forward the draw.
final class Renderer2D: NSObject, MTKViewDelegate {
    let renderer: Renderer

    init(device: MTLDevice) throws { renderer = try Renderer(device: device) }

    /// Passthrough so MainWindowController can sync state without knowing about
    /// the underlying Renderer. Renderer2D.draw reads `renderer.currentCamera`.
    var currentCamera: Camera {
        get { renderer.currentCamera }
        set { renderer.currentCamera = newValue }
    }

    var background: MTLClearColor {
        get { renderer.background }
        set { renderer.background = newValue }
    }

    var scene: Scene {
        get { renderer.scene }
        set { renderer.scene = newValue }
    }

    var selectedKPathNode: Int? {
        get { renderer.selectedKPathNode }
        set { renderer.selectedKPathNode = newValue }
    }

    var coordinationNumbers: [Int] {
        get { renderer.coordinationNumbers }
        set { renderer.coordinationNumbers = newValue }
    }

    var showCoordinationColors: Bool {
        get { renderer.showCoordinationColors }
        set { renderer.showCoordinationColors = newValue }
    }

    internal func installBrillouinZoneCache(bz: BrillouinZone?, candidates: [BZCandidate]) {
        renderer.installBrillouinZoneCache(bz: bz, candidates: candidates)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = renderer.commandQueue.makeCommandBuffer() else { return }
        var cam = renderer.currentCamera
        cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        cam.perspective = false
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(view.drawableSize.width),
                             height: Double(view.drawableSize.height),
                             znear: 0, zfar: 1)
        if renderer.encode(to: cb, target: drawable.texture, viewport: vp, camera: cam) {
            cb.present(drawable)
        }
        cb.commit()
    }
}
