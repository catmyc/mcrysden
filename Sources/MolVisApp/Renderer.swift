import Metal
import MetalKit
import simd

// GPUMirror of the Metal InstanceData layout. Metal's float3 in a struct reserves
// 16 bytes (3 floats + 4-byte tail pad), so radius lands at offset 80, not 76.
// We align by using a 16-byte float4 for color on BOTH sides, eliminating the
// ambiguity entirely. The shader consumes color.rgb.
struct InstanceData { var model: float4x4; var color: SIMD4<Float>; var radius: Float; var metalness: Float }
struct FrameData    { var view: float4x4; var proj: float4x4; var lightDir: SIMD3<Float> }

enum RenderError: Error { case makeCommandQueue, makeFunction, makeBuffer, makePipeline }

/// The lock-bearing render core. `encode(to:target:viewport:camera:)` is the
/// single code path used by on-screen (MTKView) and offscreen (PNG export) alike.
final class Renderer: NSObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let atomPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let library: MTLLibrary

    private let sphereMesh: Mesh
    private let cylinderMesh: Mesh
    private let sphereVB: MTLBuffer
    private let sphereIB: MTLBuffer
    private let cylinderVB: MTLBuffer
    private let cylinderIB: MTLBuffer

    private var depthPixelFormat: MTLPixelFormat = .depth32Float
    private var depthTexture: MTLTexture?
    private var depthTextureSize: (Int, Int) = (0, 0)

    var scene: Scene = Scene()
    var currentCamera = Camera()
    var background: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)

    /// Embedded Metal source (the executable does not reliably locate a bundled
    /// metallib at runtime). Also saved verbatim as Shaders.metal.
    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn  { float3 position  [[attribute(0)]]; float3 normal  [[attribute(1)]]; };
    struct LineVertexIn { float3 position [[attribute(0)]]; };

    struct InstanceData { float4x4 model; float4 color; float radius; float metalness; };
    struct FrameData    { float4x4 view; float4x4 proj; float3 lightDir; };

    struct VInOut  { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
    struct LineVOut { float4 position [[position]]; float3 color; };

    vertex VInOut v_main(VertexIn in [[stage_in]],
                         constant InstanceData &inst [[buffer(1)]],
                         constant FrameData &f [[buffer(2)]],
                         uint iid [[instance_id]]) {
        VInOut o;
        float3 p = in.position * inst.radius + inst.model[3].xyz;
        o.worldPos = p;
        o.normal = in.normal;
        o.color = inst.color.rgb;
        o.position = f.proj * f.view * float4(p, 1.0);
        return o;
    }

    fragment float4 f_main(VInOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        float3 N = normalize(in.normal);
        float3 L = normalize(f.lightDir);
        float diff = max(dot(N, L), 0.0);
        float3 ambient = in.color.rgb * 0.35;
        float3 diffuse = in.color.rgb * diff * 0.65;
        return float4(ambient + diffuse, 1.0);
    }

    vertex LineVOut lv_main(LineVertexIn in [[stage_in]],
                            constant FrameData &f [[buffer(2)]],
                            constant float3 &color [[buffer(3)]]) {
        LineVOut o; o.color = color; o.position = f.proj * f.view * float4(in.position, 1.0); return o;
    }

    fragment float4 lf_main(LineVOut in [[stage_in]]) { return float4(in.color, 1.0); }
    """

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw RenderError.makeCommandQueue }
        self.commandQueue = q

        let lib = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        self.library = lib
        guard
            let v = lib.makeFunction(name: "v_main"),
            let f = lib.makeFunction(name: "f_main"),
            let lv = lib.makeFunction(name: "lv_main"),
            let lf = lib.makeFunction(name: "lf_main")
        else { throw RenderError.makeFunction }

        let atomVD = Renderer.makeAtomVertexDescriptor()
        let atomPD = MTLRenderPipelineDescriptor()
        atomPD.vertexFunction = v
        atomPD.fragmentFunction = f
        atomPD.vertexDescriptor = atomVD
        atomPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        atomPD.depthAttachmentPixelFormat = depthPixelFormat
        self.atomPipeline = try device.makeRenderPipelineState(descriptor: atomPD)

        let lineVD = Renderer.makeLineVertexDescriptor()
        let linePD = MTLRenderPipelineDescriptor()
        linePD.vertexFunction = lv
        linePD.fragmentFunction = lf
        linePD.vertexDescriptor = lineVD
        linePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        linePD.depthAttachmentPixelFormat = depthPixelFormat
        self.linePipeline = try device.makeRenderPipelineState(descriptor: linePD)

        self.sphereMesh = Geometry.unitSphere()
        self.cylinderMesh = Geometry.unitCylinder()
        guard
            let svb = Renderer.makeInterleavedBuffer(device, mesh: sphereMesh),
            let sib = device.makeBuffer(bytes: sphereMesh.indices,
                                       length: sphereMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: []),
            let cvb = Renderer.makeInterleavedBuffer(device, mesh: cylinderMesh),
            let cib = device.makeBuffer(bytes: cylinderMesh.indices,
                                       length: cylinderMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: [])
        else { throw RenderError.makeBuffer }
        self.sphereVB = svb
        self.sphereIB = sib
        self.cylinderVB = cvb
        self.cylinderIB = cib
    }

    // MARK: - Lock-bearing encode API

    func encode(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                viewport: MTLViewport, camera: Camera) {
        let w = target.width, h = target.height
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0
        let light = normalize(SIMD3<Float>(0.4, 0.7, 1.0))

        // v1 simplification for 2D modes: orthographic projection looking
        // down +Z with no rotation. Renderer2D sets the same fields on its
        // camera copy before calling; doing it here keeps encode self-contained.
        var cam = camera
        if scene.displayMode.is2D {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            cam.perspective = false
        }

        var frame = FrameData(view: cam.viewMatrix(),
                              proj: cam.projectionMatrix(aspect: aspect),
                              lightDir: light)
        let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: [])
        ensureDepthTexture(width: w, height: h)

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = background
        if let depthTexture {
            desc.depthAttachment.texture = depthTexture
            desc.depthAttachment.loadAction = .clear
            desc.depthAttachment.storeAction = .store
            desc.depthAttachment.clearDepth = 1.0
        } else {
            // Depth texture unavailable (e.g. memoryless unsupported) — render without it.
            desc.depthAttachment.loadAction = .dontCare
            desc.depthAttachment.storeAction = .dontCare
        }

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setViewport(viewport)
        enc.setDepthStencilState(makeDepthStencilState())
        enc.setCullMode(.none)

        // Atoms
        drawAtoms(enc, frameBuffer: frameBuffer)

        // Bonds
        drawBonds(enc, frameBuffer: frameBuffer)

        // Cell frame + axes
        drawCell(enc, frameBuffer: frameBuffer)

        enc.endEncoding()
    }

    // MARK: - Atoms

    private func drawAtoms(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        var inst: [InstanceData] = []
        inst.reserveCapacity(scene.atoms.count)
        for a in scene.atoms {
            let radius = atomRadius(z: a.atomicNumber)
            if radius <= 0 { continue }                  // polyhedral/wireFrame: atoms not drawn
            let c = ElementTable.color(a.atomicNumber)
            inst.append(InstanceData(model: float4x4(translation: a.coord),
                                     color: SIMD4(c.x, c.y, c.z, 1.0),
                                     radius: radius, metalness: 0.0))
        }
        if inst.isEmpty { return }

        let buf = device.makeBuffer(bytes: inst,
                                    length: inst.count * MemoryLayout<InstanceData>.stride,
                                    options: [])
        enc.setRenderPipelineState(atomPipeline)
        enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: sphereIB.length / MemoryLayout<UInt16>.stride,
                                  indexType: .uint16,
                                  indexBuffer: sphereIB,
                                  indexBufferOffset: 0,
                                  instanceCount: inst.count)
    }

    private func atomRadius(z: Int) -> Float {
        switch scene.displayMode {
        case .spaceFill:
            return ElementTable.vdwRadius(z)
        case .wireFrame:
            return 0.06
        case .polyhedral:
            return 0
        default: // ballStick and any 2D mode
            return ElementTable.covalentRadius(z) * scene.atomScale
        }
    }

    // MARK: - Bonds

    private func drawBonds(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        let bondsDrawn: [DisplayMode] = [.ballStick, .wireFrame, .line2D, .point2D, .ballStick2D]
        guard bondsDrawn.contains(scene.displayMode) else { return }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return }

        var inst: [InstanceData] = []
        inst.reserveCapacity(scene.bonds.count)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            let a = atoms[b.i].coord, b2 = atoms[b.j].coord
            let dir = b2 - a
            let len = length(dir)
            guard len > 1e-5 else { continue }
            let mid = (a + b2) * 0.5
            let model = float4x4(translation: mid)
                * .rotation(fromYTo: dir / len)
                * float4x4(scale: SIMD3<Float>(scene.bondRadius, len, scene.bondRadius))
            let c = ElementTable.color(atoms[b.i].atomicNumber)
            inst.append(InstanceData(model: model, color: SIMD4(c.x, c.y, c.z, 1.0), radius: 1.0, metalness: 0.0))
        }
        if inst.isEmpty { return }

        let buf = device.makeBuffer(bytes: inst,
                                    length: inst.count * MemoryLayout<InstanceData>.stride,
                                    options: [])
        enc.setRenderPipelineState(atomPipeline)
        enc.setVertexBuffer(cylinderVB, offset: 0, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: cylinderIB.length / MemoryLayout<UInt16>.stride,
                                  indexType: .uint16,
                                  indexBuffer: cylinderIB,
                                  indexBufferOffset: 0,
                                  instanceCount: inst.count)
    }

    // MARK: - Cell frame + axes

    private func drawCell(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard let cell = scene.cell, scene.showCellFrame else { return }
        let a = cell.a, b = cell.b, c = cell.c
        let o = SIMD3<Float>.zero
        let corners = [o, a, a + b, b, c, a + c, b + c, a + b + c]
        // 12 edges as 24 indices into the 8 corners
        let edges: [(Int, Int)] = [
            (0,1),(1,2),(2,3),(3,0), // bottom face (o,a,a+b,b)
            (4,5),(5,6),(6,7),(7,4), // top face   (c,a+c,b+c,a+b+c)
            (0,4),(1,5),(2,6),(3,7), // verticals
        ]
        var frameVerts: [SIMD3<Float>] = []
        frameVerts.reserveCapacity(24)
        for (i, j) in edges { frameVerts.append(corners[i]); frameVerts.append(corners[j]) }
        drawLineBuffer(frameVerts, color: SIMD3<Float>(0.75, 0.75, 0.75), enc: enc, frameBuffer: frameBuffer)

        if scene.showAxes {
            drawLineBuffer([o, o + a], color: SIMD3<Float>(1, 0.2, 0.2), enc: enc, frameBuffer: frameBuffer)
            drawLineBuffer([o, o + b], color: SIMD3<Float>(0.2, 1, 0.2), enc: enc, frameBuffer: frameBuffer)
            drawLineBuffer([o, o + c], color: SIMD3<Float>(0.2, 0.2, 1), enc: enc, frameBuffer: frameBuffer)
        }
    }

    private func drawLineBuffer(_ verts: [SIMD3<Float>], color: SIMD3<Float>,
                                enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        let lineVB = device.makeBuffer(bytes: verts,
                                       length: verts.count * MemoryLayout<SIMD3<Float>>.stride,
                                       options: [])
        var c = color
        enc.setRenderPipelineState(linePipeline)
        enc.setVertexBuffer(lineVB, offset: 0, index: 0)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBytes(&c, length: MemoryLayout<SIMD3<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
    }

    // MARK: - Depth

    private func ensureDepthTexture(width: Int, height: Int) {
        if depthTextureSize.0 == width, depthTextureSize.1 == height, depthTexture != nil { return }
        let d = MTLTextureDescriptor()
        d.pixelFormat = depthPixelFormat
        d.width = width; d.height = height
        d.usage = .renderTarget
        d.storageMode = .memoryless
        depthTexture = device.makeTexture(descriptor: d)
        depthTextureSize = (width, height)
    }

    private func makeDepthStencilState() -> MTLDepthStencilState? {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }

    // MARK: - Vertex descriptors

    private static func makeAtomVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride * 2
        return vd
    }

    private static func makeLineVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride
        return vd
    }

    // MARK: - Buffers

    private static func makeInterleavedBuffer(_ device: MTLDevice, mesh: Mesh) -> MTLBuffer? {
        let stride = MemoryLayout<SIMD3<Float>>.stride * 2
        guard let buf = device.makeBuffer(length: mesh.positions.count * stride, options: []) else {
            return nil
        }
        let p = buf.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<mesh.positions.count {
            let pos = mesh.positions[i], nrm = mesh.normals[i]
            p[i * 8 + 0] = pos.x; p[i * 8 + 1] = pos.y; p[i * 8 + 2] = pos.z
            p[i * 8 + 4] = nrm.x; p[i * 8 + 5] = nrm.y; p[i * 8 + 6] = nrm.z
        }
        return buf
    }

    // MARK: - Periodic-table lookups (CPK-ish)

}

// MARK: - MTKViewDelegate (stub; Task 7 wires gestures)

extension Renderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { /* track size if needed */ }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = commandQueue.makeCommandBuffer() else { return }
        let vp = MTLViewport(originX: 0, originY: 0,
                             width: Double(view.drawableSize.width),
                             height: Double(view.drawableSize.height),
                             znear: 0, zfar: 1)
        encode(to: cb, target: drawable.texture, viewport: vp, camera: currentCamera)
        cb.present(drawable)
        cb.commit()
    }
}
