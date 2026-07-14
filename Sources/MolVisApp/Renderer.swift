import Metal
import MetalKit
import simd

// GPUMirror of the Metal InstanceData layout. Metal's float3 in a struct reserves
// 16 bytes (3 floats + 4-byte tail pad), so radius lands at offset 80, not 76.
// We align by using a 16-byte float4 for color on BOTH sides, eliminating the
// ambiguity entirely. The shader consumes color.rgb.
struct InstanceData { var model: float4x4; var color: SIMD4<Float>; var radius: Float; var metalness: Float }

/// Per-frame uniforms shared by every pipeline. Laid out to match the Metal
/// `FrameData` struct EXACTLY (float3 slots occupy 16 bytes with tail padding,
/// matching SIMD3<Float> on the CPU side). The ambient/diffuse/specular/shininess
/// slots were appended AFTER lightDir (never inserted before it) so the line and
/// gizmo pipelines — which only read view/proj/lightDir — still compile and bind.
struct FrameData {
    var view: float4x4
    var proj: float4x4
    var lightDir: SIMD3<Float>   // world-space light direction (computed from azimuth/elevation)
    var ambient: Float           // material.ambient
    var diffuse: Float           // material.diffuse
    var specular: Float          // material.specular weight
    var shininess: Float         // material.shininess exponent
    var eyePos: SIMD3<Float>     // world-space camera position (for the specular term)
}

enum RenderError: Error { case makeCommandQueue, makeFunction, makeBuffer, makePipeline }

/// The lock-bearing render core. `encode(to:target:viewport:camera:)` is the
/// single code path used by on-screen (MTKView) and offscreen (PNG export) alike.
final class Renderer: NSObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let atomPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let flat2DPipeline: MTLRenderPipelineState   // unlit screen-space quads (2D atoms)
    private let polyPipeline: MTLRenderPipelineState     // flat-shaded polyhedron triangles
    private let gradPipeline: MTLRenderPipelineState     // fullscreen gradient quad
    private let library: MTLLibrary

    private let overlayDepthState: MTLDepthStencilState?
    private var lastW: Int = 0, lastH: Int = 0    // viewport size from last encode()
    private let sphereMesh: Mesh
    private let cylinderMesh: Mesh
    private let coneMesh: Mesh
    private let sphereVB: MTLBuffer
    private let sphereIB: MTLBuffer
    private let cylinderVB: MTLBuffer
    private let cylinderIB: MTLBuffer
    private let coneVB: MTLBuffer
    private let coneIB: MTLBuffer
    private let quadVB: MTLBuffer                    // 2 triangles covering NDC

    private var depthPixelFormat: MTLPixelFormat = .depth32Float
    private var depthTexture: MTLTexture?
    private var depthTextureSize: (Int, Int) = (0, 0)

    var scene: Scene = Scene() {
        didSet {
            invalidateBrillouinZoneCache()
            cachedIsoBuffers = [nil, nil]
            cachedIsoKeys = [nil, nil]
            cachedIsoTriangleCounts = [0, 0]
            cachedFermiBuffers = []
        }
    }
    var currentCamera = Camera()

    // Brillouin-zone cache. The BZ depends only on the conventional cell + its base
    // atoms, which are static across render frames, so build it ONCE and reuse.
    // Without this, drawBrillouinZone rebuilds an O(m^3) Wigner-Seitz cell every
    // frame; a large G-star (GaAsH, ~164 vectors) makes mouse-drag seconds-laggy.
    private var cachedBZ: BrillouinZone?
    private var cachedBZKey: BZCacheKey?
    private struct BZCacheKey: Equatable {
        var cellA: SIMD3<Float>; var cellB: SIMD3<Float>; var cellC: SIMD3<Float>
        var nBase: Int; var firstBaseZ: Int
    }
    private func invalidateBrillouinZoneCache() { cachedBZ = nil; cachedBZKey = nil }

    // Isosurface cache. Marching cubes over a large grid is comparable in cost to
    // the BZ build (cubic in the sample counts); the result depends only on the
    // scalar field + the iso level, so build once and replay the vertex buffer.
    private struct IsoCacheKey: Equatable {
        var nx: Int, ny: Int, nz: Int
        var origin: SIMD3<Float>, vec0: SIMD3<Float>, vec1: SIMD3<Float>, vec2: SIMD3<Float>
        var isoLevel: Float
        var sign: Float
    }
    var background: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)

    /// Last computed world-space light direction — exposed so the orientation
    /// gizmo (a mini-scene drawn with its own FrameData) can light its arrows
    /// from the same direction as the main scene for visual consistency.
    private var currentLightDir: SIMD3<Float> = normalize(SIMD3<Float>(0.3, 0.8, 0.5))

    /// Fill a FrameData from the current scene's lighting + camera. Centralised so
    /// the main-encode and gizmo-encode paths stay byte-for-byte in sync: the
    /// light direction is derived from Lighting.azimuth/elevation (the same
    /// spherical convention the sidebar sliders drive) and the material slots come
    /// straight off scene.lighting.
    static func makeFrame(view: float4x4, proj: float4x4, lighting: Lighting, eye: SIMD3<Float>) -> FrameData {
        let az = lighting.azimuth * .pi / 180.0
        let el = lighting.elevation * .pi / 180.0
        let cel = cos(el)
        let lightDir = SIMD3<Float>(cel * cos(az), cel * sin(az), sin(el))
        return FrameData(view: view, proj: proj, lightDir: lightDir,
                         ambient: lighting.ambient, diffuse: lighting.diffuse,
                         specular: lighting.specular, shininess: lighting.shininess,
                         eyePos: eye)
    }

    /// Parse a "#rrggbb" (or "rrggbb") hex string into an MTLClearColor. Named for
    /// the call sites in encode() that switch the clear color by background type.
    /// Falls back to black on malformed input.
    static func MTLClearColorFromString(_ hex: String) -> MTLClearColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return MTLClearColorMake(0, 0, 0, 1)
        }
        return MTLClearColorMake(Double((v >> 16) & 0xFF) / 255.0,
                                 Double((v >> 8) & 0xFF) / 255.0,
                                 Double(v & 0xFF) / 255.0, 1)
    }

    /// Parse a "#rrggbb" (or "rrggbb") hex string into a linear 0…1 SIMD3<Float>.
    /// Falls back to mid-grey on malformed input so a bad hex never yields black
    /// indistinguishable from a deliberately-chosen color.
    static func float3FromHex(_ hex: String) -> SIMD3<Float> {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return SIMD3<Float>(0.5, 0.5, 0.5) }
        return SIMD3<Float>(Float((v >> 16) & 0xFF) / 255.0,
                           Float((v >> 8) & 0xFF) / 255.0,
                           Float(v & 0xFF) / 255.0)
    }

    /// Embedded Metal source (the executable does not reliably locate a bundled
    /// metallib at runtime). Also saved verbatim as Shaders.metal.
    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn  { float3 position  [[attribute(0)]]; float3 normal  [[attribute(1)]]; };
    struct LineVertexIn { float3 position [[attribute(0)]]; };
    // 2D atom vertex: NDC position + a local coord (±1) for circular discard + color.
    struct Flat2DIn { float2 position [[attribute(0)]]; float2 local [[attribute(1)]]; float3 color [[attribute(2)]]; };
    // Polyhedron vertex: world-space position + face normal + per-vertex color.
    struct PolyIn { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float3 color [[attribute(2)]]; };
    // Gradient quad vertex: NDC xy only.
    struct GradIn { float2 position [[attribute(0)]]; };

    struct InstanceData { float4x4 model; float4 color; float radius; float metalness; };
    struct FrameData { float4x4 view; float4x4 proj; float3 lightDir; float ambient; float diffuse; float specular; float shininess; float3 eyePos; };

    struct VInOut  { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
    struct LineVOut { float4 position [[position]]; float3 color; };
    struct Flat2DOut { float4 position [[position]]; float3 color; float2 local; };
    struct PolyOut { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
    struct GradOut { float4 position [[position]]; float y; };

    // Blinn-Phong shading shared by the atom/bond AND polyhedron pipelines.
    // N, worldPos are the lit fragment; albedo is its base color. The half-vector
    // H = normalize(L + V) gives the specular highlight; specular weight and the
    // exponent are driven by the FrameData material slots (specular == 0 ⇒ matte).
    float3 shade(float3 albedo, float3 N, float3 worldPos, constant FrameData &f) {
        N = normalize(N);
        float3 L = normalize(f.lightDir);
        float3 V = normalize(f.eyePos - worldPos);
        float diff = max(dot(N, L), 0.0);
        float3 H = normalize(L + V);
        float spec = (f.shininess > 0.0) ? pow(max(dot(N, H), 0.0), f.shininess) : 0.0;
        float3 color = albedo * (f.ambient + f.diffuse * diff) + float3(1.0) * f.specular * spec;
        return clamp(color, 0.0, 1.0);
    }

    vertex VInOut v_main(VertexIn in [[stage_in]],
                         constant InstanceData *insts [[buffer(1)]],
                         constant FrameData &f [[buffer(2)]],
                         uint iid [[instance_id]]) {
        VInOut o;
        constant InstanceData &inst = insts[iid];
        float4 world = inst.model * float4(in.position * inst.radius, 1.0);
        o.worldPos = world.xyz;
        o.normal = (inst.model * float4(in.normal, 0.0)).xyz;
        o.color = inst.color.rgb;
        o.position = f.proj * f.view * world;
        return o;
    }

    fragment float4 f_main(VInOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        return float4(shade(in.color, in.normal, in.worldPos, f), 1.0);
    }

    vertex LineVOut lv_main(LineVertexIn in [[stage_in]],
                            constant FrameData &f [[buffer(2)]],
                            constant float3 &color [[buffer(3)]]) {
        LineVOut o; o.color = color; o.position = f.proj * f.view * float4(in.position, 1.0); return o;
    }

    fragment float4 lf_main(LineVOut in [[stage_in]]) { return float4(in.color, 1.0); }

    // Unlit screen-space quad for 2D atoms: discard fragments outside the unit
    // circle so each atom reads as a filled disc rather than a square.
    vertex Flat2DOut flat2D_v(Flat2DIn in [[stage_in]]) {
        Flat2DOut o; o.position = float4(in.position, 0.0, 1.0); o.color = in.color; o.local = in.local; return o;
    }
    fragment float4 flat2D_f(Flat2DOut in [[stage_in]]) {
        if (length(in.local) > 1.0) discard_fragment();
        return float4(in.color, 1.0);
    }

    // Flat-shaded polyhedron triangles: same Blinn-Phong lighting as the atoms,
    // with the face normal (flat) supplied per vertex by the CPU.
    vertex PolyOut poly_v(PolyIn in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        PolyOut o; o.worldPos = in.position; o.normal = in.normal; o.color = in.color;
        o.position = f.proj * f.view * float4(in.position, 1.0); return o;
    }
    fragment float4 poly_f(PolyOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        return float4(shade(in.color, in.normal, in.worldPos, f), 1.0);
    }

    // Fullscreen vertical-gradient quad drawn behind the scene. `y` is the NDC
    // height (-1 bottom … +1 top) remapped to 0…1 to mix bottom→top. The color
    // endpoints are passed as two constant buffers.
    vertex GradOut grad_v(GradIn in [[stage_in]]) { GradOut o; o.position = float4(in.position, 1.0, 1.0); o.y = in.position.y; return o; }
    fragment float4 grad_f(GradOut in [[stage_in]],
                           constant float3 &top [[buffer(1)]],
                           constant float3 &bottom [[buffer(2)]]) {
        float t = in.y * 0.5 + 0.5;
        return float4(mix(bottom, top, t), 1.0);
    }
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
            let lf = lib.makeFunction(name: "lf_main"),
            let f2v = lib.makeFunction(name: "flat2D_v"),
            let f2f = lib.makeFunction(name: "flat2D_f"),
            let pv = lib.makeFunction(name: "poly_v"),
            let pf = lib.makeFunction(name: "poly_f"),
            let gv = lib.makeFunction(name: "grad_v"),
            let gf = lib.makeFunction(name: "grad_f")
        else { throw RenderError.makeFunction }

        // Atom/bond pipeline — lit instanced spheres/cylinders/cones.
        let atomVD = Renderer.makeAtomVertexDescriptor()
        let atomPD = MTLRenderPipelineDescriptor()
        atomPD.vertexFunction = v
        atomPD.fragmentFunction = f
        atomPD.vertexDescriptor = atomVD
        atomPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        atomPD.depthAttachmentPixelFormat = depthPixelFormat
        self.atomPipeline = try device.makeRenderPipelineState(descriptor: atomPD)

        // Line pipeline — 1px strokes (cell frame, axes, gizmo labels, measurements).
        let lineVD = Renderer.makeLineVertexDescriptor()
        let linePD = MTLRenderPipelineDescriptor()
        linePD.vertexFunction = lv
        linePD.fragmentFunction = lf
        linePD.vertexDescriptor = lineVD
        linePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        linePD.depthAttachmentPixelFormat = depthPixelFormat
        self.linePipeline = try device.makeRenderPipelineState(descriptor: linePD)

        // 2D flat pipeline — unlit screen-space quads (2D atoms as filled discs).
        let flatVD = Renderer.makeFlat2DVertexDescriptor()
        let flatPD = MTLRenderPipelineDescriptor()
        flatPD.vertexFunction = f2v
        flatPD.fragmentFunction = f2f
        flatPD.vertexDescriptor = flatVD
        flatPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        flatPD.depthAttachmentPixelFormat = depthPixelFormat
        self.flat2DPipeline = try device.makeRenderPipelineState(descriptor: flatPD)

        // Polyhedron pipeline — flat-shaded Voronoi-like cells lit by the same
        // Blinn-Phong model as the atoms (reuses shade()).
        let polyVD = Renderer.makePolyVertexDescriptor()
        let polyPD = MTLRenderPipelineDescriptor()
        polyPD.vertexFunction = pv
        polyPD.fragmentFunction = pf
        polyPD.vertexDescriptor = polyVD
        polyPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        polyPD.depthAttachmentPixelFormat = depthPixelFormat
        self.polyPipeline = try device.makeRenderPipelineState(descriptor: polyPD)

        // Gradient pipeline — fullscreen vertical gradient drawn behind the scene.
        let gradVD = Renderer.makeGradVertexDescriptor()
        let gradPD = MTLRenderPipelineDescriptor()
        gradPD.vertexFunction = gv
        gradPD.fragmentFunction = gf
        gradPD.vertexDescriptor = gradVD
        gradPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        gradPD.depthAttachmentPixelFormat = depthPixelFormat
        self.gradPipeline = try device.makeRenderPipelineState(descriptor: gradPD)

        self.sphereMesh = Geometry.unitSphere()
        self.cylinderMesh = Geometry.unitCylinder()
        self.coneMesh = Geometry.unitCone()
        guard
            let svb = Renderer.makeInterleavedBuffer(device, mesh: sphereMesh),
            let sib = device.makeBuffer(bytes: sphereMesh.indices,
                                       length: sphereMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: []),
            let cvb = Renderer.makeInterleavedBuffer(device, mesh: cylinderMesh),
            let cib = device.makeBuffer(bytes: cylinderMesh.indices,
                                       length: cylinderMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: []),
            let gvb = Renderer.makeInterleavedBuffer(device, mesh: coneMesh),
            let gib = device.makeBuffer(bytes: coneMesh.indices,
                                       length: coneMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: []),
            let qvb = Renderer.makeQuadBuffer(device)
        else { throw RenderError.makeBuffer }
        self.sphereVB = svb
        self.sphereIB = sib
        self.cylinderVB = cvb
        self.cylinderIB = cib
        self.coneVB = gvb
        self.coneIB = gib
        self.quadVB = qvb
        self.overlayDepthState = Renderer.makeOverlayDepthState(device: device)
    }

    /// Depth state for the orientation gizmo: always pass, never write, so the
    /// triad overlays the scene regardless of what was drawn before it.
    private static func makeOverlayDepthState(device: MTLDevice) -> MTLDepthStencilState? {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always
        d.isDepthWriteEnabled = false
        return device.makeDepthStencilState(descriptor: d)
    }

    // MARK: - Lock-bearing encode API

    func encode(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                viewport: MTLViewport, camera: Camera) {
        let w = target.width, h = target.height
        lastW = w; lastH = h
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0

        // v1 simplification for 2D modes: orthographic projection looking
        // down +Z with no rotation. Renderer2D sets the same fields on its
        // camera copy before calling; doing it here keeps encode self-contained.
        var cam = camera
        if scene.displayMode.is2D {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            cam.perspective = false
        }

        var frame = Renderer.makeFrame(view: cam.viewMatrix(),
                                       proj: cam.projectionMatrix(aspect: aspect),
                                       lighting: scene.lighting,
                                       eye: cam.eyePosition())
        let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: [])
        ensureDepthTexture(width: w, height: h)

        // Clear color reflects the CURRENT background type + hex, recomputed every
        // frame so sidebar edits apply immediately (previously frozen at init).
        let clearColor = scene.backgroundType == .gradient_top
            ? Renderer.MTLClearColorFromString(scene.backgroundBottom)
            : Renderer.MTLClearColorFromString(scene.background)

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = clearColor
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
        enc.setCullMode(.none)
        // Standard less-than depth test for the scene. The gradient pass (below)
        // and the gizmo/measurements both swap this to an overlay state of their
        // own and restore it, so this is the authoritative default.
        enc.setDepthStencilState(makeDepthStencilState())

        // Vertical-gradient backdrop: a fullscreen quad at the far plane, drawn
        // with the always-pass / never-write overlay depth state so the scene
        // (depth < 1.0) paints over it. Reuses the gizmo's overlay depth state.
        if scene.backgroundType == .gradient_top {
            drawGradient(enc)
        }

        // The atomic structure (atoms/bonds/polyhedra) can be hidden so the user
        // can focus on the cell frame, axes, or Brillouin-zone overlay. The
        // frame/axes/BZ branches below draw regardless.
        if scene.showStructure {
            if scene.displayMode.is2D {
                // True 2D: flat screen-space atom discs + 1px bond lines. The cell
                // frame and axes already draw correctly in 2D and stay on.
                drawAtoms2D(enc, frameBuffer: frameBuffer, w: w, h: h)
                drawBonds2D(enc, frameBuffer: frameBuffer)
            } else if scene.displayMode == .polyhedral {
                // Polyhedral: hide spheres/bonds, build+draw convex cells.
                drawPolyhedral(enc, frameBuffer: frameBuffer)
            } else {
                // Atoms (instanced spheres)
                drawAtoms(enc, frameBuffer: frameBuffer)

                // Bonds (instanced cylinders)
                drawBonds(enc, frameBuffer: frameBuffer)
            }
            // Force arrows (instanced lines): drawn for any 3D mode that shows real
            // atom positions in world space (ball-stick/space-fill/wireframe AND
            // polyhedral), so the vectors map to the same coordinates as the atoms.
            // 2D modes are excluded: they route through Renderer2D (a separate
            // renderer with no arrow path) and project atoms to screen space, where
            // a world-space arrow has no meaningful projection.
            if !scene.displayMode.is2D {
                drawForceArrows(enc, frameBuffer: frameBuffer)
            }
        }

        // Cell frame + axes
        drawCell(enc, frameBuffer: frameBuffer)

        // Brillouin-zone wireframe overlay (crystal only): the Wigner-Seitz cell
        // of the reciprocal lattice, drawn depth-tested so it sits correctly
        // around the structure and rotates with the camera.
        if scene.showBrillouinZone {
            drawBrillouinZone(enc, frameBuffer: frameBuffer)
        }

        // Isosurface over a volumetric scalar field (DATAGRID / .cube), drawn as a
        // depth-tested lit surface so it sits correctly among the atoms.
        drawIsosurface(enc, frameBuffer: frameBuffer)

        // Fermi surface: one isosurface per band, all at the Fermi energy, tinted
        // per band. Drawn after the scalar iso so both can coexist.
        drawFermiSurface(enc, frameBuffer: frameBuffer)

        // Screen-space orientation gizmo (fixed-size x/y/z arrows pinned to the
        // corner; rotates with the camera, never scales with zoom).
        if scene.showAxes {
            drawOrientationGizmo(enc, camera: cam, w: w, h: h)
        }

        // Measurement lines between selected atoms — drawn last as a depth-
        // disabled overlay so they stay readable through bonds, plus a small
        // dot at any locked-in measurement atom.
        drawMeasurements(enc, frameBuffer: frameBuffer)

        enc.endEncoding()
    }

    /// Draw the vertical-gradient backdrop quad (called only when backgroundType
    /// == .gradient_top). Held at NDC z = 1.0 (far) with the overlay depth state
    /// (always-pass, never-write) so it never occludes the scene; the scene draw
    /// resets the depth state to .less afterwards.
    private func drawGradient(_ enc: MTLRenderCommandEncoder) {
        enc.setDepthStencilState(overlayDepthState)          // always-pass, never-write
        enc.setRenderPipelineState(gradPipeline)
        enc.setVertexBuffer(quadVB, offset: 0, index: 0)
        var top = Renderer.float3FromHex(scene.background)
        var bottom = Renderer.float3FromHex(scene.backgroundBottom)
        enc.setFragmentBytes(&top, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        enc.setFragmentBytes(&bottom, length: MemoryLayout<SIMD3<Float>>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.setDepthStencilState(makeDepthStencilState())     // restore for the scene
    }

    // MARK: - Atoms

    private func drawAtoms(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        let selected = Set(scene.selectedAtoms)
        var inst: [InstanceData] = []
        inst.reserveCapacity(scene.atoms.count)
        for (i, a) in scene.atoms.enumerated() {
            let radius = atomRadius(z: a.atomicNumber)
            if radius <= 0 { continue }                  // polyhedral/wireFrame: atoms not drawn
            var c = ElementTable.color(a.atomicNumber)
            if selected.contains(i) {
                c = SIMD3<Float>(1, 1, 0.2)               // bright yellow highlight
            }
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

    // MARK: - Force arrows

    /// Draw an arrow per atom along its parsed force vector (eV/Å), scaled by
    /// `scene.forceScale` into an Å length. Shaft is a world-space line from the
    /// atom to atom+force; the head is a short barbed fork at the tip, all drawn
    /// through the existing line pipeline. Gated on `scene.forceSet` presence and
    /// the `showForces` toggle, so files without forces draw nothing.
    private func drawForceArrows(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard scene.forceSet != nil, scene.showForces else { return }
        let atoms = scene.atoms
        guard !atoms.isEmpty else { return }
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(atoms.count * 8)
        let scale = scene.forceScale
        let headFrac: Float = 0.18      // head length as a fraction of shaft
        let headSpread: Float = 0.5
        for a in atoms {
            // After supercell widening every replica carries its own `force`
            // (copied from its base atom in widenSuperCell), so the arrow is
            // drawn from each atom's own guard — NOT truncated to the base-cell
            // count. (Each replica's force vector is identical to its base's,
            // which is physically correct for a periodic structure.)
            guard let f = a.force else { continue }
            let flen = length(f)
            guard flen > 1e-6 else { continue }    // no arrow for a ~zero force
            let start = a.coord
            let tip = start + f * scale
            verts.append(start); verts.append(tip)
            // Head: two short segments splaying back from the tip along a
            // perpendicular to the shaft. Build a stable perpendicular.
            let dir = f / flen
            let perp = makePerpendicular(dir)
            let side = simd_length(f) * scale * headFrac
            let back = tip - dir * side
            let left = back + perp * side * headSpread
            let right = back - perp * side * headSpread
            verts.append(tip); verts.append(left)
            verts.append(tip); verts.append(right)
        }
        if verts.isEmpty { return }
        drawLineBuffer(verts, color: SIMD3<Float>(1.0, 0.55, 0.1), enc: enc, frameBuffer: frameBuffer)
    }

    /// A unit vector perpendicular to `d` (assumed unit-length).
    private func makePerpendicular(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let cand = abs(d.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return normalize(cand - d * simd_dot(cand, d))
    }

    // MARK: - True 2D primitives (flat screen-space atoms + 1px bonds)

    /// Project a world point to normalized device coordinates using the given
    /// view/proj. Returns NDC xy (the flat 2D shader places its quads directly
    /// in NDC, ignoring depth).
    private func projectNDC(_ world: SIMD3<Float>, view: float4x4, proj: float4x4) -> SIMD2<Float> {
        let clip = proj * view * SIMD4<Float>(world, 1)
        guard clip.w > 1e-6 else { return SIMD2<Float>(0, 0) }
        return SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
    }

    /// Read the view matrix out of a FrameData buffer (for projection helpers).
    private func sceneView(_ fb: MTLBuffer?) -> float4x4 {
        (fb?.contents().assumingMemoryBound(to: FrameData.self).pointee.view) ?? matrix_identity_float4x4
    }

    /// Read the projection matrix out of a FrameData buffer.
    private func sceneProj(_ fb: MTLBuffer?) -> float4x4 {
        (fb?.contents().assumingMemoryBound(to: FrameData.self).pointee.proj) ?? matrix_identity_float4x4
    }

    /// 2D atoms: a filled disc per atom, drawn as a small screen-space quad that
    /// the flat shader masks to a unit circle. Avoids the tessellated sphere so
    /// these modes are cheap and resolution-independent.
    private func drawAtoms2D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?, w: Int, h: Int) {
        let view = sceneView(frameBuffer)
        let proj = sceneProj(frameBuffer)
        let atoms = scene.atoms
        guard !atoms.isEmpty else { return }
        let selected = Set(scene.selectedAtoms)

        struct V { var px: Float; var py: Float; var lx: Float; var ly: Float; var r: Float; var g: Float; var b: Float }
        var verts: [V] = []
        verts.reserveCapacity(atoms.count * 6)
        let wF = Float(w), hF = Float(h)
        for (i, a) in atoms.enumerated() {
            let ndc = projectNDC(a.coord, view: view, proj: proj)
            // Pixel radius: a couple px for points; a scaled covalent radius for
            // ball-stick. Converted to NDC via the viewport size.
            let rPx: Float = scene.displayMode == .point2D
                ? 2.5
                : max(3.0, ElementTable.covalentRadius(a.atomicNumber) * scene.atomScale * 12.0)
            let rx = rPx / (wF * 0.5)
            let ry = rPx / (hF * 0.5)
            var c = ElementTable.color(a.atomicNumber)
            if selected.contains(i) { c = SIMD3<Float>(1, 1, 0.2) }
            // Two triangles (6 verts), each carrying its local (±1) coord so the
            // fragment shader discards outside the unit circle.
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (-1, 1), (-1, 1), (1, -1), (1, 1)]
            for (lx, ly) in corners {
                verts.append(V(px: ndc.x + lx * rx, py: ndc.y + ly * ry, lx: lx, ly: ly, r: c.x, g: c.y, b: c.z))
            }
        }
        if verts.isEmpty { return }
        let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: [])
        enc.setRenderPipelineState(flat2DPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    /// 2D bonds: 1px lines between projected atom endpoints, reusing the line
    /// pipeline (which already draws crisp 1px strokes). The frame's ortho
    /// view/proj carries the projection; we just feed world-space endpoints.
    private func drawBonds2D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard scene.displayMode == .ballStick2D || scene.displayMode == .line2D else { return }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return }
        var lineVerts: [SIMD3<Float>] = []
        lineVerts.reserveCapacity(scene.bonds.count * 2)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            lineVerts.append(atoms[b.i].coord)
            lineVerts.append(atoms[b.j].coord)
        }
        if lineVerts.isEmpty { return }
        drawLineBuffer(lineVerts, color: SIMD3<Float>(0.35, 0.35, 0.35), enc: enc, frameBuffer: frameBuffer)
    }

    // MARK: - Polyhedral display mode (convex Voronoi-like cells)

    /// Build the neighbor coordinate list for every atom from `scene.bonds`,
    /// sorted nearest-first (polyhedronFaces clamps to its limit on a
    /// first-come basis, so the closest neighbors win).
    private func buildNeighborCoords() -> [[SIMD3<Float>]] {
        let atoms = scene.atoms
        var neigh: [[SIMD3<Float>]] = Array(repeating: [], count: atoms.count)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            neigh[b.i].append(atoms[b.j].coord)
            neigh[b.j].append(atoms[b.i].coord)
        }
        for i in 0..<neigh.count {
            let c = atoms[i].coord
            neigh[i].sort { length($0 - c) < length($1 - c) }
        }
        return neigh
    }

    /// Polyhedral mode: for each atom with >=3 neighbors, intersect the
    /// perpendicular-bisector half-spaces to build a convex cell and render it
    /// as flat-shaded triangles through the lit polyhedron pipeline. Atoms with
    /// too few neighbors (termini) are skipped — the surrounding cells expand to
    /// fill the gap.
    private func drawPolyhedral(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        let atoms = scene.atoms
        guard atoms.count > 1 else { return }
        let neigh = buildNeighborCoords()
        let selected = Set(scene.selectedAtoms)

        // Packed vertex: world pos (3) + face normal (3) + color (3). Drawn as a
        // plain triangle list through the lit poly pipeline (no instancing).
        struct V { var x: Float; var y: Float; var z: Float; var nx: Float; var ny: Float; var nz: Float; var r: Float; var g: Float; var b: Float }
        var verts: [V] = []
        for (i, a) in atoms.enumerated() {
            guard neigh[i].count >= 3 else { continue }
            guard let tris = Geometry.polyhedronFaces(center: a.coord, neighbors: neigh[i], maxNeighbors: 12) else { continue }
            var col = ElementTable.color(a.atomicNumber)
            if selected.contains(i) { col = SIMD3<Float>(1, 1, 0.2) }
            // tris is a flat list of triangle vertices (groups of 3). Compute a
            // flat normal per triangle and assign it to each of its 3 vertices.
            var j = 0
            while j < tris.count {
                let p0 = tris[j], p1 = tris[j + 1], p2 = tris[j + 2]
                let n = normalize(cross(p1 - p0, p2 - p0))
                for p in [p0, p1, p2] {
                    verts.append(V(x: p.x, y: p.y, z: p.z, nx: n.x, ny: n.y, nz: n.z, r: col.x, g: col.y, b: col.z))
                }
                j += 3
            }
        }
        if verts.isEmpty { return }
        let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: [])
        enc.setRenderPipelineState(polyPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)   // FrameData for lighting
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    // MARK: - Cell frame + axes

    /// The 12 edges of a parallelepiped in terms of its 8 corner indices:
    /// corners = [o, a, a+b, b, c, a+c, b+c, a+b+c].
    static let cellEdges: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,0), // bottom face (o,a,a+b,b)
        (4,5),(5,7),(7,6),(6,4), // top face   (c,a+c,a+b+c,b+c)
        (0,4),(1,5),(2,7),(3,6), // verticals
    ]

    private func drawCell(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard let cell = scene.cell else { return }
        let a = cell.a, b = cell.b, c = cell.c
        // Center the displayed cells on the structure centroid so the set of
        // supercell boxes encloses the atoms (otherwise atoms at negative
        // fractional coords, e.g. ZnS, would fall outside the origin box).
        let n = max(1, scene.atoms.count)
        var centroid = SIMD3<Float>.zero
        for at in scene.atoms { centroid += at.coord }
        centroid /= Float(n)

        // Draw one unit-cell box per supercell replica.  The base origin of
        // the box array is chosen so the AVERAGE of all box centres equals
        // the structure centroid (single-box formula for n1=n2=n3=1).
        let sc = scene.superCell
        let base = centroid - (Float(sc.n1) * 0.5) * a
                          - (Float(sc.n2) * 0.5) * b
                          - (Float(sc.n3) * 0.5) * c
        if scene.showCellFrame {
            let edges = Renderer.cellEdges
            var frameVerts: [SIMD3<Float>] = []
            frameVerts.reserveCapacity(24 * sc.total)
            for i in 0..<sc.n1 {
                for j in 0..<sc.n2 {
                    for k in 0..<sc.n3 {
                        let t = a * Float(i) + b * Float(j) + c * Float(k)
                        let o = base + t
                        let corners = [o, a + o, a + b + o, b + o, c + o, a + c + o, b + c + o, a + b + c + o]
                        for (ci, cj) in edges { frameVerts.append(corners[ci]); frameVerts.append(corners[cj]) }
                    }
                }
            }
            drawLineBuffer(frameVerts, color: SIMD3<Float>(0.75, 0.75, 0.75), enc: enc, frameBuffer: frameBuffer)
        }

    }

    /// Draw measurement lines between selected atoms in 3D space.
    private func drawMeasurements(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        // Only draw connecting lines while a measurement mode is active — never
        // in plain Selection mode (.none).
        guard scene.measurementMode != .none else { return }
        let sel = scene.selectedAtoms
        guard sel.count >= 2 else { return }
        let atoms = scene.atoms
        // connect consecutive selected atoms in order
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(sel.count * 2)
        for i in 0..<(sel.count - 1) {
            guard sel[i] < atoms.count, sel[i+1] < atoms.count else { return }
            verts.append(atoms[sel[i]].coord)
            verts.append(atoms[sel[i+1]].coord)
        }
        // The orientation gizmo sets a corner sub-viewport; restore the full
        // target viewport before drawing measurement lines.
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(lastW), height: Double(lastH),
                                    znear: 0, zfar: 1))
        // Draw as a depth-disabled overlay (like the orientation gizmo) so the
        // lines stay readable where they pass behind bonds or atoms.
        enc.setDepthStencilState(overlayDepthState)
        drawLineBuffer(verts, color: SIMD3<Float>(0.2, 0.6, 1), enc: enc, frameBuffer: frameBuffer)
    }

    /// Screen-space orientation gizmo: a fixed-size triad of bold arrows pinned
    /// to the bottom-left corner of the viewport, showing how the world x/y/z
    /// axes are currently oriented. It rotates as you orbit but never scales
    /// with zoom.
    ///
    /// Arrows are real lit 3D geometry (cylinder shaft + cone head) drawn
    /// through the SAME pipeline as atoms and bonds, in a miniature scene of
    /// their own: a view matrix built from just the camera rotation (so the
    /// triad spins with your orbit) and a fixed orthographic projection sized
    /// to a corner sub-viewport (so the arrows keep a constant pixel size at
    /// any zoom). This is the standard orientation-gizmo construction.
    private func drawOrientationGizmo(_ enc: MTLRenderCommandEncoder, camera: Camera, w: Int, h: Int) {
        // Corner sub-viewport (pixels); Metal origin is top-left, +y down.
        let gSize = max(72.0, Double(min(w, h)) * 0.16)
        let margin = 14.0
        enc.setViewport(MTLViewport(originX: margin, originY: Double(h) - gSize - margin,
                                    width: gSize, height: gSize, znear: 0, zfar: 1))

        // Mini-camera: rotation-only view + fixed orthographic projection. The
        // gizmo is lit from the SAME scene.lighting as the main scene (via
        // makeFrame) so its arrows' shading is consistent with what you see.
        let R = float4x4(camera.rotation).transpose            // world -> view (no translation)
        let half: Float = 1.05
        let proj = float4x4(orthographicLeft: -half, right: half, bottom: -half, top: half,
                            near: -10, far: 10)
        // Eye far down +Z in the gizmo's rotation-only space — purely to give
        // the specular term a stable view vector; distance is irrelevant.
        var frame = Renderer.makeFrame(view: R, proj: proj,
                                       lighting: scene.lighting,
                                       eye: SIMD3<Float>(0, 0, 100))
        let fb = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: [])
        enc.setRenderPipelineState(atomPipeline)
        enc.setDepthStencilState(overlayDepthState)

        let shaftLen: Float = 0.62, shaftR: Float = 0.05
        let headLen: Float = 0.22, headR: Float = 0.13
        // Unit cylinder/cone point +Y; rotate each onto its axis direction.
        func shaftModel(_ dir: SIMD3<Float>) -> float4x4 {
            float4x4(translation: dir * shaftLen * 0.5) * .rotation(fromYTo: dir) *
            float4x4(scale: SIMD3<Float>(shaftR, shaftLen, shaftR))
        }
        func headModel(_ dir: SIMD3<Float>) -> float4x4 {
            float4x4(translation: dir * shaftLen) * .rotation(fromYTo: dir) *
            float4x4(scale: SIMD3<Float>(headR, headLen, headR))
        }
        struct Axis { let dir: SIMD3<Float>; let color: SIMD3<Float> }
        let axes = [
            Axis(dir: SIMD3<Float>(1, 0, 0), color: SIMD3<Float>(1, 0.2, 0.2)), // x red
            Axis(dir: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(0.2, 1, 0.2)), // y green
            Axis(dir: SIMD3<Float>(0, 0, 1), color: SIMD3<Float>(0.2, 0.2, 1)), // z blue
        ]

        // Draw shafts (cylinders) and heads (cones) as two instanced passes.
        func drawInstances(_ meshVB: MTLBuffer, _ meshIB: MTLBuffer,
                           _ model: (SIMD3<Float>) -> float4x4) {
            var inst: [InstanceData] = []
            for a in axes {
                inst.append(InstanceData(model: model(a.dir), color: SIMD4(a.color, 1),
                                         radius: 1.0, metalness: 0.0))
            }
            let buf = device.makeBuffer(bytes: inst, length: inst.count * MemoryLayout<InstanceData>.stride, options: [])
            enc.setVertexBuffer(meshVB, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setVertexBuffer(fb, offset: 0, index: 2)
            enc.setFragmentBuffer(fb, offset: 0, index: 2)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: meshIB.length / MemoryLayout<UInt16>.stride,
                                      indexType: .uint16, indexBuffer: meshIB, indexBufferOffset: 0,
                                      instanceCount: inst.count)
        }
        drawInstances(cylinderVB, cylinderIB, shaftModel)
        drawInstances(coneVB, coneIB, headModel)

        // x/y/z letter labels at each arrow tip (line-pipeline strokes).
        // Letters are short line segments in the xy-plane, offset past the tip.
        let tipLen = shaftLen + headLen
        let lo: Float = tipLen + 0.07         // distance from origin
        let hs: Float = 0.04                  // half-size of each letter
        typealias V = SIMD3<Float>
        let labelData: [(V, V, [V])] = [
            (V(lo,0,0), V(1,0.2,0.2), [V(-hs,-hs,0),V(hs,hs,0), V(-hs,hs,0),V(hs,-hs,0)]),
            (V(0,lo,0), V(0.2,1,0.2), [V(-hs,hs,0),V(0,0,0), V(hs,hs,0),V(0,0,0), V(0,0,0),V(0,-hs,0)]),
            (V(0,0,lo), V(0.2,0.2,1), [V(-hs,hs,0),V(hs,hs,0), V(hs,hs,0),V(-hs,-hs,0), V(-hs,-hs,0),V(hs,-hs,0)]),
        ]
        enc.setRenderPipelineState(linePipeline)
        for (pos, col, segs) in labelData {
            let verts = segs.map { $0 + pos }    // offset from local origin to arrow tip
            var c = col
            let cb = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: [])!
            let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD3<Float>>.stride, options: [])
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBuffer(cb, offset: 0, index: 3)
            enc.setVertexBuffer(fb, offset: 0, index: 2)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: segs.count)
        }
    }

    private func drawLineBuffer(_ verts: [SIMD3<Float>], color: SIMD3<Float>,
                                enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        let lineVB = device.makeBuffer(bytes: verts,
                                       length: verts.count * MemoryLayout<SIMD3<Float>>.stride,
                                       options: [])
        var c = color
        let colorBuf = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: [])
        enc.setRenderPipelineState(linePipeline)
        enc.setVertexBuffer(lineVB, offset: 0, index: 0)
        enc.setVertexBuffer(colorBuf, offset: 0, index: 3)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
    }

    /// Draw the Brillouin-zone wireframe of the crystal's reciprocal lattice.
    /// The BZ lives in reciprocal space (units of 2pi/A); we normalise it by its
    /// largest extent and overlay it centered on the structure so it sits around
    /// the atoms like a reciprocal-space cage.
    private func drawBrillouinZone(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard let cell = scene.cell else { return }
        // baseAtoms are the pristine atoms in the conventional cell; their
        // fractional offsets reveal the centering so the BZ shape is right. The BZ
        // is cached because it's purely a function of (cell, baseAtoms) and those
        // don't change between frames — rebuilding the O(m^3) Wigner-Seitz cell
        // every frame is what made dragging laggy for large G-stars.
        let key = BZCacheKey(cellA: cell.a, cellB: cell.b, cellC: cell.c,
                             nBase: scene.baseAtoms.count,
                             firstBaseZ: scene.baseAtoms.first?.atomicNumber ?? 0)
        if cachedBZ == nil || cachedBZKey != key {
            cachedBZ = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms)
            cachedBZKey = key
        }
        guard let bz = cachedBZ else { return }
        // The BZ lives in reciprocal space (units of 2pi/A). Scale it to a fixed
        // fraction of the structure's bounding sphere so it renders as a visible
        // cage around the atoms — an absolute normalisation would make it a
        // microscopic speck for large cells (e.g. GaAsH, ~20 A wide) and hide it
        // among the front atoms. Centered on the structure centroid.
        var extent: Float = 0
        for face in bz.faces { for v in face { extent = max(extent, length(v)) } }
        guard extent > 1e-5 else { return }
        let (_, radius) = scene.boundingSphere()
        let targetExtent = max(1.0, radius) * 0.45
        let inv = targetExtent / extent
        let center = sceneCentroid()
        let bzColor = SIMD3<Float>(0.85, 0.30, 0.95)
        for face in bz.faces {
            let mapped = face.map { center + $0 * inv }
            // drawLineBuffer draws with Metal .line (independent vertex PAIRS), so
            // to trace a closed polygon we must emit consecutive edge pairs
            // (v0,v1),(v1,v2),...,(vN,v0) explicitly — passing the raw loop would
            // skip every other edge.
            var segs: [SIMD3<Float>] = []
            for i in 0..<mapped.count {
                let a = mapped[i]
                let b = mapped[(i + 1) % mapped.count]
                segs.append(a); segs.append(b)
            }
            drawLineBuffer(segs, color: bzColor, enc: enc, frameBuffer: frameBuffer)
        }
        // Special points as tiny crosses (instanced points would need a
        // pipeline; reuse short line segments for a simple marker).
        for sp in bz.specialPoints where sp.type != .center {
            let p = center + sp.coord * inv
            let d: Float = 0.012
            drawLineBuffer([p - SIMD3(d,0,0), p + SIMD3(d,0,0)], color: SIMD3(1,1,1),
                           enc: enc, frameBuffer: frameBuffer)
            drawLineBuffer([p - SIMD3(0,d,0), p + SIMD3(0,d,0)], color: SIMD3(1,1,1),
                           enc: enc, frameBuffer: frameBuffer)
        }
    }

    // MARK: - Isosurface

    /// Draw the isosurface (marching-cubes mesh over the scene's scalar field) as
    /// a depth-tested triangle surface. Two complementary shells are drawn at
    /// +iso and -iso, tinted differently so positive and negative orbital lobes
    /// remain distinguishable. Cached per (field signature + iso level + sign).
    private func drawIsosurface(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard let field = scene.scalarField, scene.showIsoSurface else { return }
        let iso = scene.isoLevel
        // Draw the positive shell first, then the negative shell.
        let shells: [(sign: Float, color: SIMD3<Float>)] = [
            (1, SIMD3<Float>(0.30, 0.62, 0.95)),   // outside: cool blue
            (-1, SIMD3<Float>(0.95, 0.45, 0.25)),   // inside:  warm orange
        ]
        for shell in shells {
            let key = IsoCacheKey(nx: field.nx, ny: field.ny, nz: field.nz,
                                  origin: field.origin,
                                  vec0: field.vec[0], vec1: field.vec[1], vec2: field.vec[2],
                                  isoLevel: iso, sign: shell.sign)
            let cacheIndex = shell.sign > 0 ? 0 : 1
            let needsBuild = cachedIsoBuffers[cacheIndex] == nil || cachedIsoKeys[cacheIndex] != key
            if needsBuild {
                let mesh = IsoMesh(field: field, isoLevel: iso, sign: shell.sign, color: shell.color)
                cachedIsoBuffers[cacheIndex] = mesh.triangleCount > 0
                    ? device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride, options: [])
                    : nil
                cachedIsoKeys[cacheIndex] = key
                cachedIsoTriangleCounts[cacheIndex] = mesh.triangleCount
            }
            guard let buf = cachedIsoBuffers[cacheIndex], cachedIsoTriangleCounts[cacheIndex] > 0 else { continue }
            enc.setRenderPipelineState(polyPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)   // FrameData (lighting)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cachedIsoTriangleCounts[cacheIndex] * 3)
        }
    }

    // Per-shell isosurface cache (index 0 = outside/sign>0, 1 = inside/sign<0).
    private var cachedIsoBuffers: [MTLBuffer?] = [nil, nil]
    private var cachedIsoKeys: [IsoCacheKey?] = [nil, nil]
    private var cachedIsoTriangleCounts: [Int] = [0, 0]

    // MARK: - Fermi surface (multi-band isosurface at the Fermi level)

    /// Per-band Fermi-surface mesh cache. Each band has identical geometry but
    /// different values, so its surface shape differs; cache each band's vertex
    /// buffer once (the Fermi level is fixed for a given file).
    private var cachedFermiBuffers: [MTLBuffer] = []

    /// A small per-band color palette so the overlapping bands read distinctly.
    private static let fermiPalette: [SIMD3<Float>] = [
        SIMD3<Float>(0.95, 0.30, 0.30),  // red
        SIMD3<Float>(0.30, 0.85, 0.40),  // green
        SIMD3<Float>(0.35, 0.55, 0.95),  // blue
        SIMD3<Float>(0.95, 0.75, 0.20),  // amber
        SIMD3<Float>(0.75, 0.35, 0.95),  // violet
        SIMD3<Float>(0.30, 0.85, 0.85),  // teal
    ]

    /// Draw each band of a Fermi surface as an independent isosurface at the
    /// Fermi energy, tinted per band. Depth-tested so the bands interleave
    /// correctly as the user orbits.
    private func drawFermiSurface(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) {
        guard let fs = scene.fermiSurface, scene.showFermiSurface else { return }
        // rebuild the per-band buffers when the band count changes
        if cachedFermiBuffers.count != fs.bands.count {
            var bufs: [MTLBuffer?] = []
            for (idx, band) in fs.bands.enumerated() {
                let color = Renderer.fermiPalette[idx % Renderer.fermiPalette.count]
                let mesh = IsoMesh(field: band, isoLevel: fs.fermiEnergy, sign: 1, color: color)
                let buf = mesh.triangleCount > 0
                    ? device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride, options: [])
                    : nil
                bufs.append(buf)
            }
            cachedFermiBuffers = bufs.compactMap { $0 }
        }
        enc.setRenderPipelineState(polyPipeline)
        for buf in cachedFermiBuffers {
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
            // buf.length / (9 floats/vertex) is already the vertex count (3 per
            // triangle) — drawing triCount*3 reads past the populated buffer.
            let vertexCount = buf.length / (9 * MemoryLayout<Float>.stride)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
    }

    /// Centroid of the (super)atom set, used to center overlays.
    private func sceneCentroid() -> SIMD3<Float> {
        let n = scene.atoms.count
        guard n > 0 else { return SIMD3<Float>.zero }
        var c = SIMD3<Float>.zero
        for a in scene.atoms { c += a.coord }
        return c / Float(n)
    }

    private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }

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

    // --- Vertex descriptors for the OTHER agent's added pipelines ----------------
    // These mirror the shader vertex structs declared in shaderSource (Flat2DIn,
    // PolyIn, GradIn) so their pipelines set up in init() can bind. Pure plumbing
    // — no shader/draw logic is touched.

    /// Flat2DIn: float2 position @0, float2 local @1, float3 color @2.
    ///
    /// The Swift vertex buffer packs position + local as two float2 (16 bytes)
    /// followed by r/g/b as three *bare* Float (12 bytes), so the real stride is
    /// 28. We must not round the color up to a SIMD3 stride (16) — Metal would
    /// then advance 32 bytes per vertex and read garbage after the first atom,
    /// blowing each tiny screen-space quad into a huge corrupted triangle.
    private static func makeFlat2DVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        let float2Stride = MemoryLayout<SIMD2<Float>>.stride   // 8
        let colorStride = MemoryLayout<Float>.stride * 3       // 12 (3 bare Floats)
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = float2Stride               // 8
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float3
        vd.attributes[2].offset = float2Stride * 2            // 16
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = float2Stride * 2 + colorStride // 28
        return vd
    }

    /// PolyIn: float3 position @0, float3 normal @1, float3 color @2.
    ///
    /// The Swift vertex buffer packs each attribute as 3 *bare* Float (12 bytes),
    /// not SIMD3 (16). Offsets 0/12/24, stride 36 — matching the packed `V`
    /// struct in drawPolyhedral. Using SIMD3 stride (48) here would misalign
    /// every vertex after the first.
    private static func makePolyVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        let s = MemoryLayout<Float>.stride * 3   // 12 (3 bare Floats)
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = s             // 12
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float3
        vd.attributes[2].offset = s * 2         // 24
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = s * 3            // 36
        return vd
    }

    /// GradIn: float2 position @0 only (fullscreen NDC quad).
    private static func makeGradVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        return vd
    }

    /// Two triangles covering NDC (-1…1) for the gradient/2D fullscreen pass.
    private static func makeQuadBuffer(_ device: MTLDevice) -> MTLBuffer? {
        let verts: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2( 1, -1), SIMD2(-1,  1),
            SIMD2(-1,  1), SIMD2( 1, -1), SIMD2( 1,  1),
        ]
        return device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride, options: [])
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
