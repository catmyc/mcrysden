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
    var lightDir: SIMD3<Float>   // world-space direction of the camera-relative light
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
    private let depthStencilState: MTLDepthStencilState?
    /// Depth state for the BZ k-path route overlay: less-than-or-equal compare with
    /// DEPTH WRITES DISABLED. Route segments/nodes share the BZ landmarks' depth, so
    /// a strict `.less` compare can drop equal-depth route fragments behind the white
    /// landmarks drawn moments earlier. `.lessEqual` lets the selected route overlay
    /// those coincident lines while still respecting scene occlusion (unlike
    /// `.always`). Switched in only while drawing the route overlay; the main
    /// depthStencilState is restored immediately after so isosurfaces/Fermi surfaces
    /// keep their existing depth behavior. Required: the route overlay cannot render
    /// without it, so init fails (throws) if the device cannot create it rather than
    /// silently leaving the route invisible.
    private let routeDepthState: MTLDepthStencilState
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
        /// Invalidate only caches whose inputs changed; see `invalidateCaches`.
        didSet { invalidateCaches(old: oldValue) }
    }
    var currentCamera = Camera()

    // Brillouin-zone cache. The BZ depends only on the conventional cell + its base
    // atoms, which are static across render frames, so build it ONCE and reuse.
    // Without this, drawBrillouinZone rebuilds an O(m^3) Wigner-Seitz cell every
    // frame; a large G-star (GaAsH, ~164 vectors) makes mouse-drag seconds-laggy.
    private var cachedBZ: BrillouinZone?
    private var bzBuilt = false          // true once build() has run (even if it returned nil)
    private(set) var bzRebuildCount = 0
    // Landmark candidates derived from the cached BZ. `bz.candidates()` does scale
    // conversion, O(n²) de-duplication, sorting and labelling — far cheaper than the
    // BZ build but still worth computing ONCE per cached BZ, not every frame. Nil
    // until the first build; an empty list negative-caches a nil BZ. Route-only
    // scene changes leave this untouched (invalidation keys on cell/baseAtoms).
    private var cachedCandidates: [BZCandidate]?
    private(set) var bzCandidateComputeCount = 0
    // Large white BZ-landmark crosses are clutter on the inactive overlay, so they
    // draw only while the user is editing the k-path on the BZ (kept in sync with
    // SideBarState.editKPathOnBZ by MainWindowController.syncFromState). Non-persisted:
    // a pure render toggle, not part of Scene. Defaults off.
    var showBZLandmarks = false
    /// Index of the route node to highlight in the BZ viewport (mirrors the
    /// sidebar's selected route node), or nil for no highlight. Non-persisted:
    /// a pure render toggle kept in sync by MainWindowController, like
    /// `showBZLandmarks`. Compared against the per-frame node index in
    /// `drawKPathRoute`, so an out-of-range value is simply not drawn.
    var selectedKPathNode: Int? = nil
    private func invalidateBrillouinZoneCache() {
        cachedBZ = nil; bzBuilt = false
        cachedCandidates = nil
    }

    // Isosurface cache. Marching cubes over a large grid is comparable in cost to
    // the BZ build (cubic in the sample counts); the result depends only on the
    // scalar field + the iso level, so build once and replay the vertex buffer.
    //
    // The key deliberately does NOT carry the values array (storing [Float] in the
    // per-frame key and comparing element-wise would be O(n) every frame). Instead it
    // carries a renderer-owned `generation` token: a counter bumped only when the
    // field's content, geometry, or iso level actually change (see
    // `scalarFieldGeneration`). The per-frame key comparison — including that token
    // — is therefore O(1) and retains no array.
    private struct IsoCacheKey: Equatable {
        var nx: Int, ny: Int, nz: Int
        var origin: SIMD3<Float>, vec0: SIMD3<Float>, vec1: SIMD3<Float>, vec2: SIMD3<Float>
        var isoLevel: Float
        var sign: Float
        var generation: UInt64
    }
    var background: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)
    /// Optional clear-color override for exports; when set, encode uses it instead
    /// of deriving the clear color from the scene background. Reset to nil after use.
    var clearColorOverride: MTLClearColor?

    /// Renderer-owned token for the current scalar field. Bumped in
    /// `invalidateCaches` exactly when the iso field's content, geometry, or iso
    /// level change — so two frames built against the SAME cacheable field share a
    /// generation, while any content change yields a new one and forces a rebuild.
    ///
    /// Content changes are detected exactly (no hashing) via CoW storage-identity:
    /// `ScalarField.values` is immutable and Swift Array is copy-on-write, so two
    /// arrays sharing a storage base address hold identical content. See
    /// `sameValueStorage`. A freed-and-reused buffer address cannot alias a stale
    /// value because the base-address check is exact, not probabilistic.
    private var scalarFieldGeneration: UInt64 = 1

    /// Exact content equality for two immutable [Float] value arrays, with an O(1)
    /// copy-on-write fast path — no hashing, no dimension truncation.
    ///
    /// Swift Array is CoW and `ScalarField.values` is never mutated, so two arrays
    /// whose non-empty storage shares a base address hold identical content: the
    /// `sameBase` check is both sound and O(1). Empty arrays share a nil base and
    /// are always equal (`[] == []`), so the nil-base case is exact too. When
    /// storage differs we fall back to exact `==` — but that only happens at a real
    /// content mutation, never on an appearance-only edit or per-frame.
    private func sameValueStorage(_ a: [Float], _ b: [Float]) -> Bool {
        let sameBase = a.withUnsafeBufferPointer { ba in
            b.withUnsafeBufferPointer { bb in ba.baseAddress == bb.baseAddress }
        }
        return sameBase || a == b
    }

    /// Test-only seam: when false, the next per-frame buffer allocation in
    /// `encode` fails, exercising the makeBuffer → encode → exporter failure path
    /// deterministically (CI Metal allocations never fail on their own). Reset to
    /// true after use. Not consulted anywhere except the frame-buffer allocation.
    static var forceNextBufferAllocationSuccess = true

    /// Last computed world-space light direction — exposed so the orientation
    /// gizmo (a mini-scene drawn with its own FrameData) can light its arrows
    /// from the same direction as the main scene for visual consistency.
    private var currentLightDir: SIMD3<Float> = normalize(SIMD3<Float>(0.3, 0.8, 0.5))

    /// Fill a FrameData from the current scene's lighting + camera. Centralised so
    /// the main-encode and gizmo-encode paths stay byte-for-byte in sync. The
    /// sidebar's azimuth/elevation describe a camera-space light, which is
    /// transformed into world space so orbiting the structure changes which
    /// surfaces face the viewer-fixed light.
    static func makeFrame(view: float4x4, proj: float4x4, lighting: Lighting, eye: SIMD3<Float>) -> FrameData {
        let az = lighting.azimuth * .pi / 180.0
        let el = lighting.elevation * .pi / 180.0
        let cel = cos(el)
        let viewLight = SIMD3<Float>(cel * cos(az), cel * sin(az), sin(el))
        let lightDir = normalize((view.transpose * SIMD4<Float>(viewLight, 0)).xyz)
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
    /// metallib at runtime). This string is the runtime source of truth.
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

    // Correct normal matrix (inverse-transpose of the linear 3x3) under nonuniform
    // scale. Derived in-shader by hand (cofactor / determinant) because MSL's
    // matrix intrinsics are unavailable to this toolchain, and InstanceData's
    // layout can't carry a separate normal matrix. normalMatrix == cofactor(M)/det
    // since cofactor^T/det = inverse(M) and we want transpose(inverse(M)).
    float3x3 normalMatrix3x3(float3x3 m) {
        // MSL indexes matrices as m[column][row]. Name these by mathematical row.
        float a = m[0][0], b = m[1][0], c = m[2][0];
        float d = m[0][1], e = m[1][1], f = m[2][1];
        float g = m[0][2], h = m[1][2], k = m[2][2];
        // cofactor matrix entries (sign pattern + - + / - + - / + - +).
        float c00 =  (e*k - f*h), c01 = -(d*k - f*g), c02 =  (d*h - e*g);
        float c10 = -(b*k - c*h), c11 =  (a*k - c*g), c12 = -(a*h - b*g);
        float c20 =  (b*f - c*e), c21 = -(a*f - c*d), c22 =  (a*e - b*d);
        float det = a*c00 + b*c01 + c*c02;
        if (abs(det) < 1e-12) return float3x3(1.0);
        return float3x3(float3(c00, c10, c20) / det,
                        float3(c01, c11, c21) / det,
                        float3(c02, c12, c22) / det);
    }

    vertex VInOut v_main(VertexIn in [[stage_in]],
                         constant InstanceData *insts [[buffer(1)]],
                         constant FrameData &f [[buffer(2)]],
                         uint iid [[instance_id]]) {
        VInOut o;
        constant InstanceData &inst = insts[iid];
        float4 world = inst.model * float4(in.position * inst.radius, 1.0);
        o.worldPos = world.xyz;
        // Normals transformed by the inverse-transpose of the model's linear 3x3
        // so nonuniform scale (e.g. bond cylinders stretched along their length)
        // keeps them orthogonal to the surface. InstanceData's layout can't carry
        // a normal matrix, so derive it in-shader from the model. For rigid
        // (rotation) + uniform scale this reduces to the linear part, matching the
        // prior result. Computed by hand (cofactor/determinant) — see normalMatrix3x3.
        float3x3 model3 = float3x3(inst.model[0].xyz, inst.model[1].xyz, inst.model[2].xyz);
        float3x3 normalMatrix = normalMatrix3x3(model3);
        o.normal = normalMatrix * in.normal;
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
        self.depthStencilState = Renderer.makeDepthStencilState(device: device)
        // The route overlay cannot render without this state, so fail init (rather
        // than silently leaving the route invisible) if the device rejects it.
        guard let routeDepthState = Renderer.makeRouteDepthState(device: device) else {
            throw RenderError.makeBuffer
        }
        self.routeDepthState = routeDepthState
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

    /// Render the scene for one frame. Returns false if no render command encoder
    /// could be created (e.g. the command buffer/texture is invalid) — callers
    /// that write output must treat a false return as failure rather than a
    /// successful blank frame.
    @discardableResult
    func encode(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                viewport: MTLViewport, camera: Camera) -> Bool {
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
        if !Renderer.forceNextBufferAllocationSuccess {
            Renderer.forceNextBufferAllocationSuccess = true
            return false
        }
        guard let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        guard ensureDepthTexture(width: w, height: h) else { return false }

        // Clear color: explicit override (for exports) takes priority, else derive
        // from the current background type + hex so sidebar edits apply immediately.
        let clearColor: MTLClearColor
        if let override = clearColorOverride {
            clearColor = override
        } else {
            clearColor = scene.backgroundType == .gradient_top
                ? Renderer.MTLClearColorFromString(scene.backgroundBottom)
                : Renderer.MTLClearColorFromString(scene.background)
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = clearColor
        if let depthTexture {
            desc.depthAttachment.texture = depthTexture
            desc.depthAttachment.loadAction = .clear
            desc.depthAttachment.storeAction = .dontCare
            desc.depthAttachment.clearDepth = 1.0
        }

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return false }
        enc.setViewport(viewport)
        enc.setCullMode(.none)
        // Standard less-than depth test for the scene. The gradient pass (below)
        // and the gizmo/measurements both swap this to an overlay state of their
        // own and restore it, so this is the authoritative default. The state is
        // cached at init; if it could not be created, disable rendering rather than
        // submit a frame with no depth test.
        guard let depthStencilState else { enc.endEncoding(); return false }
        enc.setDepthStencilState(depthStencilState)

        // Vertical-gradient backdrop. Suppressed during exports with an explicit
        // clearColorOverride so transparent/custom backgrounds render as configured.
        if scene.backgroundType == .gradient_top && clearColorOverride == nil {
            drawGradient(enc)
        }

        // The atomic structure (atoms/bonds/polyhedra) can be hidden so the user
        // can focus on the cell frame, axes, or Brillouin-zone overlay. The
        // frame/axes/BZ branches below draw regardless.
        if scene.showStructure {
            if scene.displayMode.is2D {
                guard drawAtoms2D(enc, frameBuffer: frameBuffer, w: w, h: h) else { enc.endEncoding(); return false }
                guard drawBonds2D(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
            } else if scene.displayMode == .polyhedral {
                guard drawPolyhedral(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
            } else {
                guard drawAtoms(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
                guard drawBonds(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
            }
            if !scene.displayMode.is2D {
                guard drawForceArrows(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
            }
        }

        guard drawCell(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }

        if scene.showBrillouinZone {
            guard drawBrillouinZone(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
        }

        guard drawIsosurface(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }
        guard drawFermiSurface(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }

        if scene.showAxes {
            guard drawOrientationGizmo(enc, camera: cam, w: w, h: h) else { enc.endEncoding(); return false }
        }

        guard drawMeasurements(enc, frameBuffer: frameBuffer) else { enc.endEncoding(); return false }

        enc.endEncoding()
        return true
    }

    /// Draw the vertical-gradient backdrop quad (called only when backgroundType
    /// == .gradient_top). Held at NDC z = 1.0 (far) with the overlay depth state
    /// (always-pass, never-write) so it never occludes the scene; the scene draw
    /// resets the depth state to .less afterwards.
    @discardableResult
    private func drawGradient(_ enc: MTLRenderCommandEncoder) -> Bool {
        enc.setDepthStencilState(overlayDepthState)          // always-pass, never-write
        enc.setRenderPipelineState(gradPipeline)
        enc.setVertexBuffer(quadVB, offset: 0, index: 0)
        var top = Renderer.float3FromHex(scene.background)
        var bottom = Renderer.float3FromHex(scene.backgroundBottom)
        enc.setFragmentBytes(&top, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        enc.setFragmentBytes(&bottom, length: MemoryLayout<SIMD3<Float>>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.setDepthStencilState(depthStencilState)           // restore for the scene
        return true
    }

    // MARK: - Atoms

    @discardableResult
    private func drawAtoms(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
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
        if inst.isEmpty { return true }

        guard let buf = device.makeBuffer(bytes: inst,
                                          length: inst.count * MemoryLayout<InstanceData>.stride,
                                          options: []) else { return false }
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
        return true
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

    @discardableResult
    private func drawBonds(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let bondsDrawn: [DisplayMode] = [.ballStick, .wireFrame, .line2D, .point2D, .ballStick2D]
        guard bondsDrawn.contains(scene.displayMode) else { return true }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }

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
        if inst.isEmpty { return true }

        guard let buf = device.makeBuffer(bytes: inst,
                                          length: inst.count * MemoryLayout<InstanceData>.stride,
                                          options: []) else { return false }
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
        return true
    }

    // MARK: - Force arrows

    /// Draw an arrow per atom along its parsed force vector (eV/Å), scaled by
    /// `scene.forceScale` into an Å length. Shaft is a world-space line from the
    /// atom to atom+force; the head is a short barbed fork at the tip, all drawn
    /// through the existing line pipeline. Gated on `scene.forceSet` presence and
    /// the `showForces` toggle, so files without forces draw nothing.
    @discardableResult
    private func drawForceArrows(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard scene.forceSet != nil, scene.showForces else { return true }
        let atoms = scene.atoms
        guard !atoms.isEmpty else { return true }
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(atoms.count * 8)
        let scale = scene.forceScale
        let headFrac: Float = 0.18
        let headSpread: Float = 0.5
        for a in atoms {
            guard let f = a.force else { continue }
            let flen = length(f)
            guard flen > 1e-6 else { continue }
            let start = a.coord
            let tip = start + f * scale
            verts.append(start); verts.append(tip)
            let dir = f / flen
            let perp = makePerpendicular(dir)
            let side = simd_length(f) * scale * headFrac
            let back = tip - dir * side
            let left = back + perp * side * headSpread
            let right = back - perp * side * headSpread
            verts.append(tip); verts.append(left)
            verts.append(tip); verts.append(right)
        }
        if verts.isEmpty { return true }
        return drawLineBuffer(verts, color: SIMD3<Float>(1.0, 0.55, 0.1), enc: enc, frameBuffer: frameBuffer)
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
    @discardableResult
    private func drawAtoms2D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?, w: Int, h: Int) -> Bool {
        let view = sceneView(frameBuffer)
        let proj = sceneProj(frameBuffer)
        let atoms = scene.atoms
        guard !atoms.isEmpty else { return true }
        let selected = Set(scene.selectedAtoms)

        struct V { var px: Float; var py: Float; var lx: Float; var ly: Float; var r: Float; var g: Float; var b: Float }
        var verts: [V] = []
        verts.reserveCapacity(atoms.count * 6)
        let wF = Float(w), hF = Float(h)
        for (i, a) in atoms.enumerated() {
            let ndc = projectNDC(a.coord, view: view, proj: proj)
            let rPx: Float = scene.displayMode == .point2D
                ? 2.5
                : max(3.0, ElementTable.covalentRadius(a.atomicNumber) * scene.atomScale * 12.0)
            let rx = rPx / (wF * 0.5)
            let ry = rPx / (hF * 0.5)
            var c = ElementTable.color(a.atomicNumber)
            if selected.contains(i) { c = SIMD3<Float>(1, 1, 0.2) }
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (-1, 1), (-1, 1), (1, -1), (1, 1)]
            for (lx, ly) in corners {
                verts.append(V(px: ndc.x + lx * rx, py: ndc.y + ly * ry, lx: lx, ly: ly, r: c.x, g: c.y, b: c.z))
            }
        }
        if verts.isEmpty { return true }
        guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else { return false }
        enc.setRenderPipelineState(flat2DPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        return true
    }

    /// 2D bonds: 1px lines between projected atom endpoints, reusing the line
    /// pipeline (which already draws crisp 1px strokes). The frame's ortho
    /// view/proj carries the projection; we just feed world-space endpoints.
    @discardableResult
    private func drawBonds2D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard scene.displayMode == .ballStick2D || scene.displayMode == .line2D else { return true }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }
        var lineVerts: [SIMD3<Float>] = []
        lineVerts.reserveCapacity(scene.bonds.count * 2)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            lineVerts.append(atoms[b.i].coord)
            lineVerts.append(atoms[b.j].coord)
        }
        if lineVerts.isEmpty { return true }
        return drawLineBuffer(lineVerts, color: SIMD3<Float>(0.35, 0.35, 0.35), enc: enc, frameBuffer: frameBuffer)
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
    /// fill the gap. Caches vertex buffer across camera-only frames.
    @discardableResult
    private func drawPolyhedral(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }
        let key = (atoms: atoms, bonds: scene.bonds, selected: scene.selectedAtoms)
        if let pk = cachedPolyKey,
           pk.selected == key.selected,
           pk.atoms.count == key.atoms.count, zip(pk.atoms, key.atoms).allSatisfy({ $0.coord == $1.coord && $0.atomicNumber == $1.atomicNumber }),
           pk.bonds.count == key.bonds.count, zip(pk.bonds, key.bonds).allSatisfy({ $0.i == $1.i && $0.j == $1.j }) {
            // cache hit (possibly an empty mesh). Draw only if geometry is present.
            if cachedPolyVertexCount > 0, let cachedPolyBuffer {
                enc.setRenderPipelineState(polyPipeline)
                enc.setVertexBuffer(cachedPolyBuffer, offset: 0, index: 0)
                enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
                enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cachedPolyVertexCount)
            }
            return true
        }
        let neigh = buildNeighborCoords()
        let selected = Set(scene.selectedAtoms)

        struct V { var x: Float; var y: Float; var z: Float; var nx: Float; var ny: Float; var nz: Float; var r: Float; var g: Float; var b: Float }
        var verts: [V] = []
        for (i, a) in atoms.enumerated() {
            guard neigh[i].count >= 3 else { continue }
            guard let tris = Geometry.polyhedronFaces(center: a.coord, neighbors: neigh[i], maxNeighbors: 12) else { continue }
            var col = ElementTable.color(a.atomicNumber)
            if selected.contains(i) { col = SIMD3<Float>(1, 1, 0.2) }
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
        // negative-cache empty geometry so camera-only frames skip the rebuild.
        if verts.isEmpty {
            cachedPolyKey = key
            cachedPolyBuffer = nil
            cachedPolyVertexCount = 0
            return true
        }
        guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else {
            // Don't commit the key on allocation failure, or the hit branch would
            // persistently skip the now-nil buffer and never retry.
            return false
        }
        cachedPolyKey = key
        cachedPolyBuffer = buf
        cachedPolyVertexCount = verts.count
        enc.setRenderPipelineState(polyPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        return true
    }

    // MARK: - Cell frame + axes

    /// The 12 edges of a parallelepiped in terms of its 8 corner indices:
    /// corners = [o, a, a+b, b, c, a+c, b+c, a+b+c].
    static let cellEdges: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,0), // bottom face (o,a,a+b,b)
        (4,5),(5,7),(7,6),(6,4), // top face   (c,a+c,a+b+c,b+c)
        (0,4),(1,5),(2,7),(3,6), // verticals
    ]

    /// Overflow-safe, strictly-positive supercell replica count; nil if any factor is
    /// non-positive or the product overflows. Mirrors `Scene.positiveProduct` (kept
    /// file-private there) so `drawCell` can bound its box reserve and nested loops
    /// without importing the GUI's widenSuperCell path.
    private static func cellBoxCount(_ sc: SuperCell) -> Int? {
        guard sc.n1 > 0, sc.n2 > 0, sc.n3 > 0 else { return nil }
        let ab = sc.n1.multipliedReportingOverflow(by: sc.n2)
        guard !ab.overflow else { return nil }
        let abc = ab.partialValue.multipliedReportingOverflow(by: sc.n3)
        return abc.overflow ? nil : abc.partialValue
    }

    @discardableResult
    private func drawCell(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let cell = scene.cell else { return true }
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
            // A direct Scene construction can carry a pathological supercell (a product
            // that overflows Int, or a zero/negative factor) that the GUI's widenSuperCell
            // refuses — bound the replica count by the same atom cap the GUI enforces so
            // the reserve + loops never allocate gigabytes or hang. Any legitimately-built
            // scene stays under that ceiling, so normal rendering is unaffected.
            guard let replicas = Renderer.cellBoxCount(sc),
                  replicas <= Scene.superCellAtomCap else { return false }
            var frameVerts: [SIMD3<Float>] = []
            frameVerts.reserveCapacity(replicas * 24)
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
            return drawLineBuffer(frameVerts, color: SIMD3<Float>(0.75, 0.75, 0.75), enc: enc, frameBuffer: frameBuffer)
        }
        return true
    }

    /// Draw measurement lines between selected atoms in 3D space.
    @discardableResult
    private func drawMeasurements(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard scene.measurementMode != .none else { return true }
        let sel = scene.selectedAtoms
        guard sel.count >= 2 else { return true }
        let atoms = scene.atoms
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(sel.count * 2)
        for i in 0..<(sel.count - 1) {
            let a = sel[i], b = sel[i+1]
            // Skip a single bad pair rather than bailing and dropping the valid
            // segments collected so far; guard negatives (sel holds Int, so a stale
            // -1 passes an upper-bound check) as well as out-of-range indices.
            guard a >= 0, b >= 0, a < atoms.count, b < atoms.count else { continue }
            verts.append(atoms[a].coord)
            verts.append(atoms[b].coord)
        }
        // All pairs invalid: nothing to draw, but still a successful no-op.
        guard !verts.isEmpty else { return true }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(lastW), height: Double(lastH),
                                    znear: 0, zfar: 1))
        enc.setDepthStencilState(overlayDepthState)
        return drawLineBuffer(verts, color: SIMD3<Float>(0.2, 0.6, 1), enc: enc, frameBuffer: frameBuffer)
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
    @discardableResult
    private func drawOrientationGizmo(_ enc: MTLRenderCommandEncoder, camera: Camera, w: Int, h: Int) -> Bool {
        let gSize = max(72.0, Double(min(w, h)) * 0.16)
        let margin = 14.0
        enc.setViewport(MTLViewport(originX: margin, originY: Double(h) - gSize - margin,
                                    width: gSize, height: gSize, znear: 0, zfar: 1))

        let worldToView = float4x4(camera.rotation).transpose
        let half: Float = 1.05
        let proj = float4x4(orthographicLeft: -half, right: half, bottom: -half, top: half,
                            near: -10, far: 10)
        var arrowFrame = Renderer.makeFrame(view: matrix_identity_float4x4, proj: proj,
                                            lighting: scene.lighting,
                                            eye: SIMD3<Float>(0, 0, 100))
        guard let arrowFB = device.makeBuffer(bytes: &arrowFrame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        var labelFrame = Renderer.makeFrame(view: worldToView, proj: proj,
                                            lighting: scene.lighting,
                                            eye: SIMD3<Float>(0, 0, 100))
        guard let labelFB = device.makeBuffer(bytes: &labelFrame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        enc.setRenderPipelineState(atomPipeline)
        enc.setDepthStencilState(overlayDepthState)

        let shaftLen: Float = 0.62, shaftR: Float = 0.05
        let headLen: Float = 0.22, headR: Float = 0.13
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
            Axis(dir: (worldToView * SIMD4<Float>(1, 0, 0, 0)).xyz, color: SIMD3<Float>(1, 0.2, 0.2)),
            Axis(dir: (worldToView * SIMD4<Float>(0, 1, 0, 0)).xyz, color: SIMD3<Float>(0.2, 1, 0.2)),
            Axis(dir: (worldToView * SIMD4<Float>(0, 0, 1, 0)).xyz, color: SIMD3<Float>(0.2, 0.2, 1)),
        ]

        func drawInstances(_ meshVB: MTLBuffer, _ meshIB: MTLBuffer,
                           _ model: (SIMD3<Float>) -> float4x4) -> Bool {
            var inst: [InstanceData] = []
            for a in axes {
                inst.append(InstanceData(model: model(a.dir), color: SIMD4(a.color, 1),
                                         radius: 1.0, metalness: 0.0))
            }
            guard let buf = device.makeBuffer(bytes: inst, length: inst.count * MemoryLayout<InstanceData>.stride, options: []) else { return false }
            enc.setVertexBuffer(meshVB, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setVertexBuffer(arrowFB, offset: 0, index: 2)
            enc.setFragmentBuffer(arrowFB, offset: 0, index: 2)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: meshIB.length / MemoryLayout<UInt16>.stride,
                                      indexType: .uint16, indexBuffer: meshIB, indexBufferOffset: 0,
                                      instanceCount: inst.count)
            return true
        }
        guard drawInstances(cylinderVB, cylinderIB, shaftModel) else { return false }
        guard drawInstances(coneVB, coneIB, headModel) else { return false }

        let tipLen = shaftLen + headLen
        let lo: Float = tipLen + 0.07
        let hs: Float = 0.04
        typealias V = SIMD3<Float>
        let labelData: [(V, V, [V])] = [
            (V(lo,0,0), V(1,0.2,0.2), [V(-hs,-hs,0),V(hs,hs,0), V(-hs,hs,0),V(hs,-hs,0)]),
            (V(0,lo,0), V(0.2,1,0.2), [V(-hs,hs,0),V(0,0,0), V(hs,hs,0),V(0,0,0), V(0,0,0),V(0,-hs,0)]),
            (V(0,0,lo), V(0.2,0.2,1), [V(-hs,hs,0),V(hs,hs,0), V(hs,hs,0),V(-hs,-hs,0), V(-hs,-hs,0),V(hs,-hs,0)]),
        ]
        enc.setRenderPipelineState(linePipeline)
        for (pos, col, segs) in labelData {
            let verts = segs.map { $0 + pos }
            var c = col
            guard let cb = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: []) else { return false }
            guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD3<Float>>.stride, options: []) else { return false }
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBuffer(cb, offset: 0, index: 3)
            enc.setVertexBuffer(labelFB, offset: 0, index: 2)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: segs.count)
        }
        return true
    }

    @discardableResult
    /// Endpoints of a 3-axis cross (three orthogonal line segments of half-length
    /// `half`) centered at `world`. The segments lie along the world x/y/z axes so
    /// the cross reads correctly from any viewpoint. Returns [] for a non-finite
    /// center so callers never hand the line pipeline a garbage position.
    static func crossLineSegments(_ world: SIMD3<Float>, half: Float) -> [SIMD3<Float>] {
        guard world.x.isFinite && world.y.isFinite && world.z.isFinite else { return [] }
        guard half.isFinite, half > 0 else { return [] }
        let ax = SIMD3<Float>(half, 0, 0), ay = SIMD3<Float>(0, half, 0), az = SIMD3<Float>(0, 0, half)
        return [world - ax, world + ax, world - ay, world + ay, world - az, world + az]
    }

    private func drawLineBuffer(_ verts: [SIMD3<Float>], color: SIMD3<Float>,
                                enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let lineVB = device.makeBuffer(bytes: verts,
                                             length: verts.count * MemoryLayout<SIMD3<Float>>.stride,
                                             options: []) else { return false }
        var c = color
        guard let colorBuf = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: []) else { return false }
        enc.setRenderPipelineState(linePipeline)
        enc.setVertexBuffer(lineVB, offset: 0, index: 0)
        enc.setVertexBuffer(colorBuf, offset: 0, index: 3)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
        return true
    }

    /// Draw the Brillouin-zone wireframe of the crystal's reciprocal lattice.
    /// The BZ lives in reciprocal space (units of 2pi/A); we normalise it by its
    /// largest extent and overlay it centered on the structure so it sits around
    /// the atoms like a reciprocal-space cage. BZ cache is invalidated by
    /// invalidateCaches when cell or baseAtoms change; this method just checks
    /// cachedBZ == nil instead of reconstructing the cache key every frame.
    @discardableResult
    private func drawBrillouinZone(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let cell = scene.cell else { return true }
        // negative-cache a nil BZ so a failed build() does not rebuild every frame.
        if !bzBuilt {
            cachedBZ = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms)
            bzBuilt = true
            bzRebuildCount += 1
            // Compute the (static) landmark candidates once per cached BZ and reuse
            // them across frames; an empty list negative-caches a nil build.
            cachedCandidates = cachedBZ?.candidates() ?? []
            bzCandidateComputeCount += 1
        }
        guard let bz = cachedBZ else { return true }
        // cachedCandidates is guaranteed non-nil here: a nil BZ is caught above and
        // negative-caches an empty list, while a non-nil BZ caches its candidates.
        let candidates = cachedCandidates ?? []
        let pres = BZPresentation(bz: bz, scene: scene)
        // inv==0 (degenerate BZ, extent <= 1e-5) collapses every mapped point onto
        // the scene center; guard against a non-finite or zero scale so a malformed
        // BZ is skipped rather than drawing a degenerate blob at the origin.
        guard pres.inv.isFinite, pres.inv > 0 else { return true }
        // Displayed BZ half-extent in world units (= targetExtent). Marker arms scale
        // with it so they stay visible as the scene is zoomed; the floor keeps a
        // tiny reciprocal zone's landmarks from collapsing to sub-pixel specks.
        let displayedHalfExtent = max(1.0, scene.boundingSphere().1) * 0.45
        guard displayedHalfExtent > 1e-5 else { return true }
        let bzColor = SIMD3<Float>(0.85, 0.30, 0.95)
        let landmarkHalf = max(0.06, displayedHalfExtent * 0.10)   // white BZ landmark crosses
        let routeNodeHalf = max(0.10, displayedHalfExtent * 0.16)  // larger cyan k-path nodes

        // Face wireframe (purple) — the static BZ geometry, drawn first.
        var faceSegs: [SIMD3<Float>] = []
        for face in bz.faces {
            let mapped = face.map { pres.world(cartesian: $0) }
            for i in 0..<mapped.count {
                faceSegs.append(mapped[i])
                faceSegs.append(mapped[(i + 1) % mapped.count])
            }
        }
        let faceOK = faceSegs.isEmpty ? true : drawLineBuffer(faceSegs, color: bzColor, enc: enc, frameBuffer: frameBuffer)

        // De-duplicated landmarks (white 3-axis crosses), including Gamma. The
        // candidate list is computed once per cached BZ (see bzCandidateComputeCount);
        // each maps its BZ-space Cartesian coordinate through the shared presentation,
        // and non-finite positions are skipped by the cross helper. Hidden unless the
        // user is editing the k-path on the BZ (showBZLandmarks), so the inactive
        // overlay stays uncluttered.
        var landmarkSegs: [SIMD3<Float>] = []
        if showBZLandmarks {
            for cand in candidates {
                landmarkSegs.append(contentsOf: Renderer.crossLineSegments(pres.world(cartesian: cand.cartesian), half: landmarkHalf))
            }
        }
        let landmarkOK = landmarkSegs.isEmpty ? true : drawLineBuffer(landmarkSegs, color: SIMD3(1, 1, 1), enc: enc, frameBuffer: frameBuffer)

        // k-path route overlay: amber segments between consecutive valid nodes, and a
        // larger cyan 3-axis cross at every valid node. Drawn on top of the landmarks
        // with a `.lessEqual`/no-write depth state so equal-depth route fragments are
        // not dropped behind the white landmarks drawn a moment earlier.
        // Switch to the less-equal/no-write state for the route overlay so its
        // equal-depth fragments aren't dropped behind the landmarks drawn above,
        // then restore the authoritative state for subsequent passes.
        enc.setDepthStencilState(routeDepthState)
        let routeOK = drawKPathRoute(pres: pres, routeNodeHalf: routeNodeHalf, enc: enc, frameBuffer: frameBuffer)
        if let depthStencilState { enc.setDepthStencilState(depthStencilState) }

        return faceOK && landmarkOK && routeOK
    }

    /// Draw `scene.kPathPoints` as an amber polyline (one segment per consecutive
    /// pair of VALID nodes) plus a larger cyan 3-axis cross at each valid node.
    /// Non-finite nodes are skipped without failing the frame and never bridge a
    /// segment, and the route is capped at 1024 points. Empty routes draw nothing;
    /// a one-point route draws only its node cross.
    @discardableResult
    private func drawKPathRoute(pres: BZPresentation, routeNodeHalf: Float,
                                enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let pts = Array(scene.kPathPoints.prefix(1024))
        // Map each node once; track which map to a finite world position.
        let mapped = pts.map { pres.world(frac: $0.frac) }
        let valid = mapped.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        let breaks = scene.kPathBreaks

        var segVerts: [SIMD3<Float>] = []
        for i in 0..<mapped.count {
            // A segment joins i and i+1 only when BOTH map validly AND there is
            // no break between them. This prevents an invalid point from bridging
            // its valid neighbours and prevents a bridge across a disconnected
            // segment boundary.
            if i + 1 < mapped.count, valid[i], valid[i + 1], !breaks.contains(i) {
                segVerts.append(mapped[i])
                segVerts.append(mapped[i + 1])
            }
        }
        let amber = SIMD3<Float>(1.0, 0.55, 0.1)
        let segOK = segVerts.isEmpty ? true : drawLineBuffer(segVerts, color: amber, enc: enc, frameBuffer: frameBuffer)

        // Defense in depth against a stale controller index: validate against the
        // rendered node count and treat an out-of-range value as "no selection".
        // The controller clears the index on every wholesale route replacement, load,
        // reset, and frame change, but this guard ensures a missed clear can never
        // highlight the wrong node (an out-of-range index simply draws nothing).
        let sel = selectedKPathNode.flatMap { (0..<mapped.count).contains($0) ? $0 : nil }
        var nodeVerts: [SIMD3<Float>] = []
        var highlightVerts: [SIMD3<Float>] = []
        for i in 0..<mapped.count where valid[i] {
            if let sel, i == sel {
                // Highlighted (sidebar-selected) node: larger cross in a vivid
                // green so it reads against the cyan nodes, amber segments, and
                // purple BZ faces.
                highlightVerts.append(contentsOf: Renderer.crossLineSegments(mapped[i], half: routeNodeHalf * 1.5))
            } else {
                nodeVerts.append(contentsOf: Renderer.crossLineSegments(mapped[i], half: routeNodeHalf))
            }
        }
        let cyan = SIMD3<Float>(0.2, 0.8, 1.0)
        let nodeOK = nodeVerts.isEmpty ? true : drawLineBuffer(nodeVerts, color: cyan, enc: enc, frameBuffer: frameBuffer)
        let highlight = SIMD3<Float>(0.2, 1.0, 0.3)
        let highlightOK = highlightVerts.isEmpty ? true : drawLineBuffer(highlightVerts, color: highlight, enc: enc, frameBuffer: frameBuffer)
        return segOK && nodeOK && highlightOK
    }

    // MARK: - Isosurface

    /// Draw the isosurface (marching-cubes mesh over the scene's scalar field) as
    /// a depth-tested triangle surface. Two complementary shells are drawn at
    /// +iso and -iso, tinted differently so positive and negative orbital lobes
    /// remain distinguishable. Cached per (field signature + iso level + sign).
    @discardableResult
    private func drawIsosurface(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let field = scene.scalarField, scene.showIsoSurface else { return true }
        // A degenerate geometry (fewer than 3 span vectors) would trap on the
        // `field.vec[0..2]` indexing below when building the IsoCacheKey. Skip the
        // isosurface rather than trap; the Fermi path is protected the same way
        // through IsoMesh's own vec-count guard, so a malformed band never reaches
        // here with a short vec either.
        guard field.vec.count >= 3 else { return true }
        let iso = scene.isoLevel
        // Draw the positive shell first, then the negative shell.
        let shells: [(sign: Float, color: SIMD3<Float>)] = [
            (1, SIMD3<Float>(0.30, 0.62, 0.95)),   // outside: cool blue
            (-1, SIMD3<Float>(0.95, 0.45, 0.25)),   // inside:  warm orange
        ]
        for shell in shells {
            // The field's content is represented by the renderer-owned generation
            // token, not the values array. The token is O(1) to read, so this key
            // comparison is O(1) per frame instead of O(n). The token only changes
            // when the field's content/geometry/iso level actually change (see
            // invalidateCaches), so unchanged fields reuse the cached mesh.
            let key = IsoCacheKey(nx: field.nx, ny: field.ny, nz: field.nz,
                                  origin: field.origin,
                                  vec0: field.vec[0], vec1: field.vec[1], vec2: field.vec[2],
                                  isoLevel: iso, sign: shell.sign,
                                  generation: scalarFieldGeneration)
            let cacheIndex = shell.sign > 0 ? 0 : 1
            let needsBuild = cachedIsoKeys[cacheIndex] != key
            if needsBuild {
                isoRebuildCount += 1
                let mesh = IsoMesh(field: field, isoLevel: iso, sign: shell.sign, color: shell.color)
                // A truncated shell (triangle cap hit or Int-overflowed grid) is a
                // partial surface — never cache or render it as a complete one. Surface
                // the failure so the frame drops rather than silently drawing a
                // truncated shell. A valid empty surface (no crossing) has overflow==false
                // and falls through to the triangleCount==0 branch below.
                if mesh.overflow {
                    return false
                }
                if mesh.triangleCount > 0 {
                    // A non-empty mesh that fails to allocate is a real failure — do not
                    // cache nil as "empty", or the frame would silently drop the surface
                    // and never retry. Surface the failure instead.
                    guard let buf = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride, options: []) else {
                        return false
                    }
                    cachedIsoBuffers[cacheIndex] = buf
                } else {
                    cachedIsoBuffers[cacheIndex] = nil
                }
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
        return true
    }

    // Per-shell isosurface cache (index 0 = outside/sign>0, 1 = inside/sign<0).
    // Polyhedral cache: reuses vertex buffer across camera-only frames.
    private var cachedPolyBuffer: MTLBuffer?
    private var cachedPolyVertexCount: Int = 0
    private var cachedPolyKey: (atoms: [Atom], bonds: [Bond], selected: [Int])?

    private var cachedIsoBuffers: [MTLBuffer?] = [nil, nil]
    private var cachedIsoKeys: [IsoCacheKey?] = [nil, nil]
    private var cachedIsoTriangleCounts: [Int] = [0, 0]
    private(set) var isoRebuildCount = 0

    // MARK: - Fermi surface (multi-band isosurface at the Fermi level)

    /// Per-band Fermi-surface mesh cache. One slot per source band, INCLUDING a
    /// nil/no-crossing band (`triangleCount == 0`). Keeping nil slots means the
    /// slot count always equals `fs.bands.count`, so the rebuild guard fires only
    /// when the band COUNT changes — a noncrossing band no longer forces a
    /// rebuild every frame. The previous `[MTLBuffer]` dropped nils via
    /// `compactMap`, shrinking the count and defeating the guard.
    private var cachedFermiBuffers: [MTLBuffer?] = []

    /// Instrumentation: rebuild count, reset with the cache, asserted by tests.
    private(set) var fermiRebuildCount = 0

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
    @discardableResult
    private func drawFermiSurface(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let fs = scene.fermiSurface, scene.showFermiSurface else { return true }
        // Rebuild only when the band COUNT changes. Because cachedFermiBuffers
        // keeps one slot per band (nil for a no-crossing band), the slot count
        // always equals fs.bands.count after the first build — a noncrossing
        // band therefore never triggers a rebuild.
        if cachedFermiBuffers.count != fs.bands.count {
            var bufs: [MTLBuffer?] = []
            var ok = true
            for (idx, band) in fs.bands.enumerated() {
                let color = Renderer.fermiPalette[idx % Renderer.fermiPalette.count]
                let mesh = IsoMesh(field: band, isoLevel: fs.fermiEnergy, sign: 1, color: color)
                // A truncated band shell is a partial surface — never commit a partial
                // buffer array (its length would match fs.bands.count and defeat the
                // rebuild guard, silently dropping that band). Abort and surface it.
                if mesh.overflow {
                    ok = false
                    break
                }
                if mesh.triangleCount > 0 {
                    // A non-empty band that fails to allocate must not commit a partial
                    // array (its length would then match fs.bands.count and defeat the
                    // rebuild guard, silently dropping that band). Abort and surface it.
                    if let buf = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride, options: []) {
                        bufs.append(buf)
                    } else {
                        ok = false
                        break
                    }
                } else {
                    bufs.append(nil)   // no-crossing band: keep a nil slot
                }
            }
            guard ok else { return false }
            cachedFermiBuffers = bufs
            fermiRebuildCount += 1
        }
        enc.setRenderPipelineState(polyPipeline)
        for case let buf? in cachedFermiBuffers {
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
            let vertexCount = buf.length / (9 * MemoryLayout<Float>.stride)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        return true
    }

    /// Conditional cache invalidation. The renderer's `scene` is reassigned on
    /// EVERY sidebar change (the controller writes appearance fields into its
    /// Scene, which fires its own `scene.didSet → renderer.scene = scene`). Only
    /// invalidate a cache when its inputs actually changed — otherwise an
    /// appearance-only tweak (lighting, scales, background) rebuilds the BZ /
    /// iso / fermi caches every frame.
    private func invalidateCaches(old: Scene) {
        // Inputs each cache depends on; recomputed cheaply from the scene.
        let oldCell = old.cell
        let newCell = scene.cell
        let sameBase = old.baseAtoms.count == scene.baseAtoms.count
            && zip(old.baseAtoms, scene.baseAtoms).allSatisfy {
                $0.coord == $1.coord && $0.atomicNumber == $1.atomicNumber
            }
        if oldCell?.a != newCell?.a || oldCell?.b != newCell?.b
            || oldCell?.c != newCell?.c || !sameBase {
            invalidateBrillouinZoneCache()
        }
        if let oldPolyKey = cachedPolyKey, oldPolyKey.selected != scene.selectedAtoms
            || oldPolyKey.atoms.count != scene.atoms.count
            || zip(oldPolyKey.atoms, scene.atoms).contains(where: { $0.coord != $1.coord || $0.atomicNumber != $1.atomicNumber })
            || oldPolyKey.bonds.count != scene.bonds.count
            || zip(oldPolyKey.bonds, scene.bonds).contains(where: { $0.i != $1.i || $0.j != $1.j }) {
            cachedPolyBuffer = nil; cachedPolyVertexCount = 0; cachedPolyKey = nil
        }
        if !isoInputsUnchanged(old: old) {
            // Content, geometry, or iso level changed: any existing mesh/vertex-data
            // is stale. Bump the renderer-owned generation so the per-frame
            // IsoCacheKey comparison below forces a rebuild, and drop the cached
            // buffers/counts. Because content change is detected exactly via
            // CoW storage identity (see sameValueStorage), no O(n) scan happens on
            // an appearance-only edit where the field array storage is unchanged.
            scalarFieldGeneration += 1
            cachedIsoBuffers = [nil, nil]
            cachedIsoKeys = [nil, nil]
            cachedIsoTriangleCounts = [0, 0]
        }
        if !fermiInputsUnchanged(old: old) {
            // A Fermi band's content, geometry, band count, or Fermi energy changed:
            // drop the cached per-band buffers. The per-frame rebuild guard then sees
            // the buffer count fall below fs.bands.count and rebuilds. Per-band
            // content change is detected exactly via CoW storage identity.
            cachedFermiBuffers = []
        }
    }

    private func isoInputsUnchanged(old: Scene) -> Bool {
        let a = old.scalarField, b = scene.scalarField
        guard let a, let b else { return a == nil && b == nil }
        return a.nx == b.nx && a.ny == b.ny && a.nz == b.nz
            && a.origin == b.origin && a.vec == b.vec
            && sameValueStorage(a.values, b.values)
            && old.isoLevel == scene.isoLevel
    }

    private func fermiInputsUnchanged(old: Scene) -> Bool {
        let a = old.fermiSurface, b = scene.fermiSurface
        guard let a, let b else { return a == nil && b == nil }
        guard a.bands.count == b.bands.count, a.fermiEnergy == b.fermiEnergy else { return false }
        for (x, y) in zip(a.bands, b.bands) {
            if (x.nx, x.ny, x.nz, x.origin, x.vec) != (y.nx, y.ny, y.nz, y.origin, y.vec)
                || !sameValueStorage(x.values, y.values) {
                return false
            }
        }
        return true
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

    /// Storage modes to try for the depth render target, best-first. macOS normally
    /// uses GPU-private depth; shared is the compatibility fallback.
    static let depthStorageFallbacks: [MTLStorageMode] = [.private, .shared]

    /// Best storage mode the device accepts for a `.depth32Float` render target.
    static func preferredDepthStorageMode(device: MTLDevice) -> MTLStorageMode? {
        let probe = MTLTextureDescriptor()
        probe.pixelFormat = MTLPixelFormat.depth32Float
        probe.width = 1; probe.height = 1
        probe.usage = .renderTarget
        for mode in depthStorageFallbacks {
            probe.storageMode = mode
            if device.makeTexture(descriptor: probe) != nil { return mode }
        }
        return nil
    }

    private func ensureDepthTexture(width: Int, height: Int) -> Bool {
        if depthTextureSize.0 == width, depthTextureSize.1 == height, depthTexture != nil { return true }
        depthTexture = nil
        let d = MTLTextureDescriptor()
        d.pixelFormat = depthPixelFormat
        d.width = width; d.height = height
        d.usage = .renderTarget
        for mode in Renderer.depthStorageFallbacks {
            d.storageMode = mode
            if let texture = device.makeTexture(descriptor: d) {
                depthTexture = texture
                break
            }
        }
        depthTextureSize = (width, height)
        return depthTexture != nil
    }

    /// Authoritative scene depth state: less-than compare, write enabled. Cached
    /// at init (see `depthStencilState`); this factory exists so init can build it
    /// the same way as `makeOverlayDepthState`.
    private static func makeDepthStencilState(device: MTLDevice) -> MTLDepthStencilState? {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }

    /// Depth state for the BZ k-path route overlay. `.lessEqual` compare (route
    /// geometry shares the landmarks' depth, so strict `.less` would drop it) with
    /// depth writes disabled (the scene's depth buffer — written by structure/faces —
    /// must remain authoritative so the route still occludes/is-occluded correctly).
    private static func makeRouteDepthState(device: MTLDevice) -> MTLDepthStencilState? {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .lessEqual
        d.isDepthWriteEnabled = false
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
        let ok = encode(to: cb, target: drawable.texture, viewport: vp, camera: currentCamera)
        if ok { cb.present(drawable) }
        cb.commit()
    }
}
