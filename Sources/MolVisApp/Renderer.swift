import Metal
import MetalKit
import simd

// GPUMirror of the Metal InstanceData layout. Metal's float3 in a struct reserves
// 16 bytes (3 floats + 4-byte tail pad), so radius lands at offset 80, not 76.
// We align by using a 16-byte float4 for color on BOTH sides, eliminating the
// ambiguity entirely. The shader consumes color.rgb.
struct InstanceData { var model: float4x4; var color: SIMD4<Float>; var radius: Float; var metalness: Float; var aoFactor: Float; var shadowFactor: Float }

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
    // Appended rendering-quality fields (byte-compatible: inserted after eyePos)
    var lineWidth: Float         // scene line width in pixels (1 = original 1px)
    var opacity: Float           // scene-object opacity 0...1 (1 = opaque)
    var depthCueingStrength: Float // 0 = off; >0 fades distant fragments toward bg
    var fogNear: Float           // view-space depth at which cueing begins
    var fogFar: Float            // view-space depth at which cueing is full
    var aoStrength: Float        // 0 = off; >0 applies per-instance AO factor
    var shadowStrength: Float    // 0 = off; >0 applies per-instance shadow factor
    var backgroundColor: SIMD3<Float> // bg color depth cueing fades toward
}

enum RenderError: Error { case makeCommandQueue, makeFunction, makeBuffer, makePipeline }

/// The lock-bearing render core. `encode(to:target:viewport:camera:)` is the
/// single code path used by on-screen (MTKView) and offscreen (PNG export) alike.
final class Renderer: NSObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var atomPipeline: MTLRenderPipelineState
    private var linePipeline: MTLRenderPipelineState
    private var flat2DPipeline: MTLRenderPipelineState   // unlit screen-space quads (2D atoms)
    private var polyPipeline: MTLRenderPipelineState     // flat-shaded polyhedron triangles
    private var gradPipeline: MTLRenderPipelineState     // fullscreen gradient quad
    private var thickLinePipeline: MTLRenderPipelineState // expanded-NDC quad lines (configurable width)
    private var texQuadPipeline: MTLRenderPipelineState    // textured quad (volume slices + color plane compositing)
    private let texQuadSampler: MTLSamplerState            // linear/clamp sampler for slice/color-plane textures
    private var bgImagePipeline: MTLRenderPipelineState    // fullscreen background image quad (screen-space NDC)
    private var mergePipeline: MTLRenderPipelineState     // anaglyph dual-eye merge
    private let bgQuadVB: MTLBuffer                       // NDC quad with uv for the anaglyph-merge pass (v-inverted; see makeBgQuadBuffer)
    private let library: MTLLibrary

    /// MSAA sample count for offscreen export rendering. nil → the scene's
    /// configured `msaaSampleCount` is used (so live rendering honors the
    /// Appearance-sidebar picker). Set explicitly for an export override.
    var msaaSampleCount: Int? = nil

    /// Internal seam returning the effective MSAA sample count for the next
    /// encode: the explicit runtime/export override (`msaaSampleCount`) when
    /// set, otherwise the scene's configured count, resolved to the highest
    /// device-supported value <= the request among 8/4/2/1. Exposed so tests can
    /// prove the override/fallback/cap-1 contracts without rendering.
    var effectiveMSAACount: Int {
        resolveMSAACount(msaaSampleCount ?? scene.msaaSampleCount)
    }
    private var msaaPipelineCache: [Int: (atom: MTLRenderPipelineState, line: MTLRenderPipelineState,
                                          flat2D: MTLRenderPipelineState, poly: MTLRenderPipelineState,
                                          grad: MTLRenderPipelineState, thickLine: MTLRenderPipelineState,
                                          texQuad: MTLRenderPipelineState, bgImage: MTLRenderPipelineState)] = [:]
    private var msaaColorTexture: MTLTexture?
    private var msaaColorTextureKey: (w: Int, h: Int, samples: Int) = (0, 0, 0)
    private var msaaDepthTexture: MTLTexture?
    private var msaaDepthTextureKey: (w: Int, h: Int, samples: Int) = (0, 0, 0)

    // MARK: - Background image cache

    /// Loaded + decoded background image texture, cached per (path, device).
    /// nil when no image is loaded or the load failed (the renderer falls back
    /// to the solid/gradient background — never crashes, never fails the frame).
    private var cachedBgImageTexture: MTLTexture?
    private var cachedBgImagePath: String?
    private var cachedBgImageDevice: MTLDevice?
    /// Cached background-image quad buffer + the key it was built for, so the
    /// per-frame draw does not allocate a new MTLBuffer every call. Key is
    /// (image width, image height, view width, view height) — the uv crop
    /// depends on both the image and viewport aspect ratios.
    private var cachedBgQuadBuffer: MTLBuffer?
    private var cachedBgQuadKey: (imgW: Int, imgH: Int, viewW: Int, viewH: Int) = (0, 0, 0, 0)

    // MARK: - Anaglyph eye textures

    /// Intermediate single-sample textures for the two anaglyph eye views.
    /// Sized to the target; recreated when dimensions change.
    private var leftEyeTexture: MTLTexture?
    private var rightEyeTexture: MTLTexture?
    private var eyeTextureSize: (w: Int, h: Int) = (0, 0)

    private let overlayDepthState: MTLDepthStencilState?
    private let depthStencilState: MTLDepthStencilState?
    /// Depth state for transparent objects: less-equal compare with no depth write.
    private let transparentDepthState: MTLDepthStencilState?
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
    private var sphereMesh: Mesh
    private var cylinderMesh: Mesh
    private let coneMesh: Mesh
    private var sphereVB: MTLBuffer
    private var sphereIB: MTLBuffer
    private var cylinderVB: MTLBuffer
    private var cylinderIB: MTLBuffer
    private let coneVB: MTLBuffer
    private let coneIB: MTLBuffer
    private let quadVB: MTLBuffer                    // 2 triangles covering NDC
    private var tessellationBuiltFactor = 0

    private var depthPixelFormat: MTLPixelFormat = .depth32Float
    private var depthTexture: MTLTexture?
    private var depthTextureSize: (Int, Int) = (0, 0)

    var scene: Scene = Scene() {
        /// Invalidate only caches whose inputs changed; see `invalidateCaches`.
        didSet { invalidateCaches(old: oldValue) }
    }
    var currentCamera = Camera()

    /// Runtime-only atom coloring inputs. These are intentionally renderer state,
    /// not Scene state, so coordination coloring is never persisted.
    var coordinationNumbers: [Int] = []
    var showCoordinationColors: Bool = false
    /// Runtime-only displacement arrows from a two-structure comparison
    /// (start, vector in Å), installed by the controller; drawn at 1:1 scale.
    var displacementArrows: [(start: SIMD3<Float>, vector: SIMD3<Float>)] = []
    var showDisplacementArrows: Bool = false
    /// Runtime-only trajectory trail vertices in Å. When `showTrajectoryTrails` is
    /// true and the array is non-empty, consecutive pairs of vertices are drawn as
    /// thin line segments (a magenta trail). Non-persisted render-only state.
    var trajectoryTrails: [SIMD3<Float>] = []
    var showTrajectoryTrails: Bool = false

    /// Discrete, colorblind-readable colors indexed by coordination number. Values
    /// below zero and zero map to the first color; values >= the maximum valid
    /// palette index map to the last color. This keeps malformed or large inputs safe.
    private static let coordinationPalette: [SIMD3<Float>] = [
        SIMD3<Float>(0.267, 0.005, 0.329),
        SIMD3<Float>(0.283, 0.141, 0.458),
        SIMD3<Float>(0.254, 0.265, 0.530),
        SIMD3<Float>(0.207, 0.372, 0.553),
        SIMD3<Float>(0.164, 0.471, 0.558),
        SIMD3<Float>(0.128, 0.567, 0.551),
        SIMD3<Float>(0.135, 0.659, 0.518),
        SIMD3<Float>(0.267, 0.749, 0.441),
        SIMD3<Float>(0.478, 0.821, 0.318),
        SIMD3<Float>(0.741, 0.873, 0.150),
    ]

    static func coordinationColor(_ number: Int) -> SIMD3<Float> {
        let index = max(0, min(number, coordinationPalette.count - 1))
        return coordinationPalette[index]
    }

    /// True when atom `index` is excluded by either the active structure clip or
    /// the translational-asymmetric-unit filter for this frame.
    private func isAtomCulled(_ index: Int) -> Bool {
        if index < frameStructureCull.count && frameStructureCull[index] { return true }
        if index < frameRepetitionCull.count && frameRepetitionCull[index] { return true }
        return false
    }

    /// Pure base-color seam shared by every atom rendering path. The caller passes
    /// nil when the coordination array is not a complete match for the scene.
    static func baseAtomColor(atomicNumber: Int, coordinationNumber: Int?,
                              showCoordinationColors: Bool) -> SIMD3<Float> {
        guard showCoordinationColors, let coordinationNumber else {
            return ElementTable.color(atomicNumber)
        }
        return coordinationColor(coordinationNumber)
    }

    static func atomColor(atomicNumber: Int, coordinationNumber: Int?,
                          showCoordinationColors: Bool, selected: Bool) -> SIMD3<Float> {
        if selected { return SIMD3<Float>(1, 1, 0.2) }
        return baseAtomColor(atomicNumber: atomicNumber,
                             coordinationNumber: coordinationNumber,
                             showCoordinationColors: showCoordinationColors)
    }

    private func atomColor(at index: Int, selected: Bool) -> SIMD3<Float> {
        if selected { return SIMD3<Float>(1, 1, 0.2) }
        if let scheme = colorSchemeColor(for: index) { return scheme }
        let z = scene.atoms[index].atomicNumber
        if showCoordinationColors, coordinationNumbers.count == scene.atoms.count {
            return Renderer.coordinationColor(coordinationNumbers[index])
        }
        return elementColor(z)
    }

    /// Runtime-only per-atom color for non-elemental schemes. Returns nil when the
    /// active scheme can't be resolved (analysis stubbed / over cap) so callers keep
    /// the elemental default. Bonds and the unlit line path ignore this.
    ///
    /// The coordination/slab arrays are computed once per distinct (atoms, cell,
    /// slab, scheme, periodicDim) and cached; without this, each per-atom call
    /// rebuilt the O(n) analysis, turning a frame into O(n²).
    private func colorSchemeColor(for index: Int) -> SIMD3<Float>? {
        switch scene.atomColorScheme {
        case .elemental:
            return nil
        case .coordination:
            ensureSchemeMetrics()
            guard let cn = cachedSchemeMetrics?.coordination, cn.count > index else { return nil }
            return AtomSchemeMetrics.ramp(Float(cn[index]) / 10.0)
        case .slabFraction:
            ensureSchemeMetrics()
            guard let m = cachedSchemeMetrics?.slab, m.count > index else { return nil }
            return AtomSchemeMetrics.ramp(m[index].fraction)
        case .distanceProportional:
            ensureSchemeMetrics()
            guard let m = cachedSchemeMetrics?.slab, m.count > index else { return nil }
            let maxDist = cachedSchemeMetrics?.slabMaxDist ?? 0
            guard maxDist > 1e-6 else { return nil }
            let t = 0.5 + 0.5 * (m[index].distance / maxDist)
            return AtomSchemeMetrics.ramp(t)
        }
    }

    /// Cached coordination/slab arrays for the active color scheme, plus the
    /// max |distance| needed by `.distanceProportional` (precomputed once so the
    /// per-atom loop doesn't re-scan). Rebuilt only when `schemeFingerprint()`
    /// changes, so camera-only frames pay nothing.
    private var cachedSchemeMetrics: SchemeMetrics?
    private struct SchemeMetrics {
        var coordination: [Int]?
        var slab: [AtomSchemeMetrics.SlabPoint]?
        var slabMaxDist: Float
    }

    /// FNV-1a digest of everything the scheme metrics depend on: the atom set
    /// (reuses `atomFingerprint`), the active scheme, slab planes, cell, and the
    /// periodic dimension. Cheap to recompute and deterministic.
    private func schemeFingerprint() -> UInt64 {
        var h = atomFingerprint()
        h ^= UInt64(scene.atomColorScheme.rawValue.hashValue); h = h &* 0x100000001b3
        if let slab = scene.slab {
            for p in [slab.planeA, slab.planeB] {
                h ^= UInt64(bitPattern: Int64(p.h)); h = h &* 0x100000001b3
                h ^= UInt64(bitPattern: Int64(p.k)); h = h &* 0x100000001b3
                h ^= UInt64(bitPattern: Int64(p.l)); h = h &* 0x100000001b3
                h ^= UInt64(p.distance.bitPattern); h = h &* 0x100000001b3
            }
        }
        if let cell = scene.cell {
            for v in [cell.a, cell.b, cell.c] {
                h ^= UInt64(v.x.bitPattern); h = h &* 0x100000001b3
                h ^= UInt64(v.y.bitPattern); h = h &* 0x100000001b3
                h ^= UInt64(v.z.bitPattern); h = h &* 0x100000001b3
            }
        }
        h ^= UInt64(bitPattern: Int64(scene.periodicDim)); h = h &* 0x100000001b3
        return h
    }

    /// Compute the scheme metrics if the fingerprint changed since the last build.
    private func ensureSchemeMetrics() {
        let fp = schemeFingerprint()
        if cachedSchemeMetrics != nil, fp == cachedSchemeMetricsFP { return }
        var cache = SchemeMetrics(coordination: nil, slab: nil, slabMaxDist: 0)
        switch scene.atomColorScheme {
        case .coordination:
            cache.coordination = AtomSchemeMetrics.coordinationNumbers(scene: scene)
        case .slabFraction, .distanceProportional:
            let slab = AtomSchemeMetrics.slabMetrics(scene: scene)
            cache.slab = slab
            cache.slabMaxDist = slab?.map { abs($0.distance) }.max() ?? 0
        case .elemental:
            break
        }
        cachedSchemeMetrics = cache
        cachedSchemeMetricsFP = fp
    }
    /// Fingerprint the scheme metrics were last built against.
    private var cachedSchemeMetricsFP: UInt64 = 0

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

    /// Install a BZ that was built by the controller. The renderer remains the
    /// authority for invalidating this cache when its scene's cell or base atoms
    /// change, while route and appearance-only scene changes retain it.
    internal func installBrillouinZoneCache(bz: BrillouinZone?, candidates: [BZCandidate]) {
        cachedBZ = bz
        cachedCandidates = candidates
        bzBuilt = true
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
    struct IsoCacheKey: Equatable {
        var nx: Int, ny: Int, nz: Int
        var origin: SIMD3<Float>, vec0: SIMD3<Float>, vec1: SIMD3<Float>, vec2: SIMD3<Float>
        var isoLevel: Float
        var sign: Float
        var generation: UInt64
        // Clip-plane params (zero/nil-equivalent when no clip is active so the
        // legacy no-clip path keeps byte-identical cache keys and output).
        var clipEnabled: Bool
        var clipH: Int
        var clipK: Int
        var clipL: Int
        var clipDistance: Float
        // Per-shell color so two specs sharing level+sign but differing in color
        // get distinct cache entries (otherwise the second reuses the first's mesh
        // and renders in the wrong color). Packed into a single UInt32
        // (RGBX); the legacy pair's fixed colors are baked in, so its keys stay
        // byte-identical.
        var colorBits: UInt32
    }
    /// Test-only seam: build an IsoCacheKey for a hypothetical shell so tests can
    /// assert the key's equality contract (in particular, that color is part of it)
    /// without rendering. Mirrors the exact key construction in drawIsosurface.
    func testIsoKey(field: ScalarField, isoLevel: Float, sign: Float, color: SIMD3<Float>,
                    clip: SlicePlane?) -> IsoCacheKey {
        let clipEnabled = clip != nil
        return IsoCacheKey(
            nx: field.nx, ny: field.ny, nz: field.nz,
            origin: field.origin, vec0: field.vec[0], vec1: field.vec[1], vec2: field.vec[2],
            isoLevel: isoLevel, sign: sign, generation: 1,
            clipEnabled: clipEnabled,
            clipH: 0, clipK: 0, clipL: 0, clipDistance: 0,
            colorBits: (UInt32((color.x * 255).rounded()) << 16)
                      | (UInt32((color.y * 255).rounded()) << 8)
                      | UInt32((color.z * 255).rounded()))
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

    /// Renderer-owned token for volume-slice textures. Bumped ONLY when the scalar
    /// field's geometry or content change — NOT when the iso level or clip plane
    /// change. The iso shell cache keys off `scalarFieldGeneration` (which does
    /// include iso/clip), but slice textures are sampled directly from the field
    /// (`FieldSlice.sample` ignores isoLevel and clip), so dragging the iso slider
    /// or editing clip planes must NOT rebuild them. Keeping the tokens separate
    /// lets iso edits refresh the shells while slice textures stay cached.
    private var sliceFieldGeneration: UInt64 = 1

    /// Field geometry + content equality for the scalar field, ignoring iso level
    /// and clip. Used to detect when slice textures (which sample the raw field)
    /// actually need rebuilding.
    private func scalarFieldContentUnchanged(old: Scene) -> Bool {
        let a = old.scalarField, b = scene.scalarField
        guard let a, let b else { return a == nil && b == nil }
        return a.nx == b.nx && a.ny == b.ny && a.nz == b.nz
            && a.origin == b.origin && a.vec == b.vec
            && sameValueStorage(a.values, b.values)
    }

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

    /// Last computed world-space light direction, cached from the most recent
    /// `encode()` frame. Used as the light vector for the AO/shadow neighbor
    /// search in `computeAOShadowFactors()` and as part of that cache's key (so
    /// the AO/shadow field is rebuilt when the light orbit changes).
    private var currentLightDir: SIMD3<Float> = normalize(SIMD3<Float>(0.3, 0.8, 0.5))

    /// Fill a FrameData from the current scene's lighting + camera. Centralised so
    /// the main-encode and gizmo-encode paths stay byte-for-byte in sync. The
    /// sidebar's azimuth/elevation describe a camera-space light, which is
    /// transformed into world space so orbiting the structure changes which
    /// surfaces face the viewer-fixed light.
    static func makeFrame(view: float4x4, proj: float4x4, lighting: Lighting, eye: SIMD3<Float>,
                          backgroundColor: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> FrameData {
        let az = lighting.azimuth * .pi / 180.0
        let el = lighting.elevation * .pi / 180.0
        let cel = cos(el)
        let viewLight = SIMD3<Float>(cel * cos(az), cel * sin(az), sin(el))
        let lightDir = normalize((view.transpose * SIMD4<Float>(viewLight, 0)).xyz)
        return FrameData(view: view, proj: proj, lightDir: lightDir,
                         ambient: lighting.ambient, diffuse: lighting.diffuse,
                         specular: lighting.specular, shininess: lighting.shininess,
                         eyePos: eye,
                         lineWidth: 1.0, opacity: 1.0,
                         depthCueingStrength: 0.0, fogNear: 0.0, fogFar: 0.0,
                         aoStrength: 0.0, shadowStrength: 0.0,
                         backgroundColor: backgroundColor)
    }

    /// Resolve the multi-light rig to a single world-space light direction: the
    /// brightest enabled light wins. Returns nil when `scene.lights` is empty so
    /// the caller keeps the legacy single-light path byte-identical. The per-light
    /// color is parsed but applied only as an intensity scale here; full per-light
    /// tinting requires the optional multi-light shader path.
    private func multiLightDir(view: float4x4) -> (dir: SIMD3<Float>, intensity: Float)? {
        let enabled = scene.lights.filter { $0.enabled }
        guard !enabled.isEmpty else { return nil }
        guard let brightest = enabled.max(by: { $0.intensity < $1.intensity }) else { return nil }
        let az = brightest.azimuth * .pi / 180.0
        let el = brightest.elevation * .pi / 180.0
        let cel = cos(el)
        let viewLight = SIMD3<Float>(cel * cos(az), cel * sin(az), sin(el))
        let dir = normalize((view.transpose * SIMD4<Float>(viewLight, 0)).xyz)
        let intensity = max(0.0, min(brightest.intensity, 4.0))
        return (dir, intensity)
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
    // Thick line vertex: NDC position (expanded from world-space line segments on CPU).
    struct ThickLineIn { float3 position [[attribute(0)]]; };
    // Textured-quad vertex: world-space position + uv. Position is float4 so the
    // struct aligns cleanly (float4 + float2 = 24 bytes; the 4-byte tail pad on
    // float3 would otherwise shift the uv offset).
    struct TexQuadIn { float4 position [[attribute(0)]]; float2 uv [[attribute(1)]]; };

    struct InstanceData { float4x4 model; float4 color; float radius; float metalness; float aoFactor; float shadowFactor; };
    struct FrameData { float4x4 view; float4x4 proj; float3 lightDir; float ambient; float diffuse; float specular; float shininess; float3 eyePos; float lineWidth; float opacity; float depthCueingStrength; float fogNear; float fogFar; float aoStrength; float shadowStrength; float3 backgroundColor; };

    struct VInOut  { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; float aoFactor; float shadowFactor; };
    struct LineVOut { float4 position [[position]]; float3 color; };
    struct Flat2DOut { float4 position [[position]]; float3 color; float2 local; };
    struct PolyOut { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
    struct GradOut { float4 position [[position]]; float y; };
    struct ThickLineVOut { float4 position [[position]]; float3 color; };
    struct TexQuadVOut { float4 position [[position]]; float2 uv; };

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
        color = clamp(color, 0.0, 1.0);
        // Depth cueing: fade distant fragments toward the background color.
        if (f.depthCueingStrength > 0.0) {
            float depth = length(f.eyePos - worldPos);
            float fog = clamp((depth - f.fogNear) / (f.fogFar - f.fogNear), 0.0, 1.0);
            color = mix(color, f.backgroundColor, fog * f.depthCueingStrength);
        }
        return color;
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
        o.aoFactor = inst.aoFactor;
        o.shadowFactor = inst.shadowFactor;
        o.position = f.proj * f.view * world;
        return o;
    }

    fragment float4 f_main(VInOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        float3 color = shade(in.color, in.normal, in.worldPos, f);
        // Per-instance AO/shadow: mix(1.0, factor, strength) is a no-op when off.
        float ao = mix(1.0, in.aoFactor, f.aoStrength);
        float shadow = mix(1.0, in.shadowFactor, f.shadowStrength);
        color *= ao * shadow;
        return float4(color, f.opacity);
    }

    vertex LineVOut lv_main(LineVertexIn in [[stage_in]],
                            constant FrameData &f [[buffer(2)]],
                            constant float3 &color [[buffer(3)]]) {
        LineVOut o; o.color = color; o.position = f.proj * f.view * float4(in.position, 1.0); return o;
    }

    fragment float4 lf_main(LineVOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) { return float4(in.color, f.opacity); }

    // Unlit screen-space quad for 2D atoms: discard fragments outside the unit
    // circle so each atom reads as a filled disc rather than a square.
    vertex Flat2DOut flat2D_v(Flat2DIn in [[stage_in]]) {
        Flat2DOut o; o.position = float4(in.position, 0.0, 1.0); o.color = in.color; o.local = in.local; return o;
    }
    fragment float4 flat2D_f(Flat2DOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        if (length(in.local) > 1.0) discard_fragment();
        return float4(in.color, f.opacity);
    }

    // Flat-shaded polyhedron triangles: same Blinn-Phong lighting as the atoms,
    // with the face normal (flat) supplied per vertex by the CPU.
    vertex PolyOut poly_v(PolyIn in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        PolyOut o; o.worldPos = in.position; o.normal = in.normal; o.color = in.color;
        o.position = f.proj * f.view * float4(in.position, 1.0); return o;
    }
    fragment float4 poly_f(PolyOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        float3 color = shade(in.color, in.normal, in.worldPos, f);
        return float4(color, f.opacity);
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

    // Thick line pipeline: vertices are pre-expanded NDC positions (from world-space
    // line segments on the CPU). The vertex shader passes them straight through with
    // w=1 (no view/proj transform). Color comes from a shared constant buffer.
    vertex ThickLineVOut thickLine_v(ThickLineIn in [[stage_in]],
                                     constant float3 &color [[buffer(3)]]) {
        ThickLineVOut o;
        o.position = float4(in.position, 1.0);
        o.color = color;
        return o;
    }
    fragment float4 thickLine_f(ThickLineVOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
        return float4(in.color, f.opacity);
    }

    // Textured-quad pipeline: world-space position (w=1, view/proj applied),
    // uv passed straight through. The fragment samples an RGBA8 texture with a
    // linear/clamp sampler; alpha 0 fragments are discarded so masked slice
    // samples don't smear across the quad.
    vertex TexQuadVOut texQuad_v(TexQuadIn in [[stage_in]],
                                 constant FrameData &f [[buffer(2)]]) {
        TexQuadVOut o;
        o.position = f.proj * f.view * in.position;
        o.uv = in.uv;
        return o;
    }
    fragment float4 texQuad_f(TexQuadVOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
        float4 c = tex.sample(smp, in.uv);
        if (c.a < 1.0/255.0) discard_fragment();
        return c;
    }

    // Background-image pipeline: screen-space NDC quad (no view/proj transform),
    // uv passed straight through. Drawn first with depth write disabled so the
    // image sits behind all geometry. The fragment samples an RGBA8 texture with
    // a linear/clamp sampler — the image fully covers the frame (scale-to-cover
    // uv mapping is applied on the CPU when building the quad verts).
    struct BgImageIn { float2 position [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct BgImageOut { float4 position [[position]]; float2 uv; };
    vertex BgImageOut bgImage_v(BgImageIn in [[stage_in]]) {
        BgImageOut o; o.position = float4(in.position, 0.0, 1.0); o.uv = in.uv; return o;
    }
    fragment float4 bgImage_f(BgImageOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.uv);
    }

    // Anaglyph merge pipeline: combine two eye textures via per-channel masks.
    // leftMask/rightMask are float4 (xyz = per-channel 0/1 mask, w unused).
    // The merged result is what encode() writes to the target.
    struct MergeIn { float2 position [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct MergeOut { float4 position [[position]]; float2 uv; };
    vertex MergeOut merge_v(MergeIn in [[stage_in]]) {
        MergeOut o; o.position = float4(in.position, 0.0, 1.0); o.uv = in.uv; return o;
    }
    fragment float4 merge_f(MergeOut in [[stage_in]],
                            texture2d<float> leftEye [[texture(0)]],
                            texture2d<float> rightEye [[texture(1)]],
                            sampler smp [[sampler(0)]],
                            constant float4 &leftMask [[buffer(1)]],
                            constant float4 &rightMask [[buffer(2)]]) {
        float3 l = leftEye.sample(smp, in.uv).rgb;
        float3 r = rightEye.sample(smp, in.uv).rgb;
        float3 out;
        out.r = l.r * leftMask.r + r.r * rightMask.r;
        out.g = l.g * leftMask.g + r.g * rightMask.g;
        out.b = l.b * leftMask.b + r.b * rightMask.b;
        return float4(out, 1.0);
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
            let gf = lib.makeFunction(name: "grad_f"),
            let tlv = lib.makeFunction(name: "thickLine_v"),
            let tlf = lib.makeFunction(name: "thickLine_f"),
            let _ = lib.makeFunction(name: "texQuad_v"),
            let _ = lib.makeFunction(name: "texQuad_f"),
            let bgv = lib.makeFunction(name: "bgImage_v"),
            let bgf = lib.makeFunction(name: "bgImage_f"),
            let mgv = lib.makeFunction(name: "merge_v"),
            let mgf = lib.makeFunction(name: "merge_f")
        else { throw RenderError.makeFunction }

        // Atom/bond pipeline — lit instanced spheres/cylinders/cones.
        // Blending enabled for transparency: opacity=1.0 result is identical to opaque.
        let atomVD = Renderer.makeAtomVertexDescriptor()
        let atomPD = MTLRenderPipelineDescriptor()
        atomPD.vertexFunction = v
        atomPD.fragmentFunction = f
        atomPD.vertexDescriptor = atomVD
        atomPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        atomPD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(atomPD.colorAttachments[0])
        self.atomPipeline = try device.makeRenderPipelineState(descriptor: atomPD)

        // Line pipeline — 1px strokes (cell frame, axes, gizmo labels, measurements).
        // Blending enabled for scene-object transparency: when opacity = 1.0 the
        // blend result is identical to opaque, so default output is preserved.
        let lineVD = Renderer.makeLineVertexDescriptor()
        let linePD = MTLRenderPipelineDescriptor()
        linePD.vertexFunction = lv
        linePD.fragmentFunction = lf
        linePD.vertexDescriptor = lineVD
        linePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        linePD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(linePD.colorAttachments[0])
        self.linePipeline = try device.makeRenderPipelineState(descriptor: linePD)

        // 2D flat pipeline — unlit screen-space quads (2D atoms as filled discs).
        let flatVD = Renderer.makeFlat2DVertexDescriptor()
        let flatPD = MTLRenderPipelineDescriptor()
        flatPD.vertexFunction = f2v
        flatPD.fragmentFunction = f2f
        flatPD.vertexDescriptor = flatVD
        flatPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        flatPD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(flatPD.colorAttachments[0])
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
        Renderer.enableAlphaBlending(polyPD.colorAttachments[0])
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

        // Thick line pipeline — expanded-NDC quad lines for configurable width.
        // Blending enabled for scene-object transparency.
        let thickVD = Renderer.makeLineVertexDescriptor()
        let thickPD = MTLRenderPipelineDescriptor()
        thickPD.vertexFunction = tlv
        thickPD.fragmentFunction = tlf
        thickPD.vertexDescriptor = thickVD
        thickPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        thickPD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(thickPD.colorAttachments[0])
        self.thickLinePipeline = try device.makeRenderPipelineState(descriptor: thickPD)

        // Textured-quad pipeline: samples an RGBA8 texture for volume slices and
        // color-plane compositing. Depth-tested so the quad composites correctly
        // with structure/isosurfaces.
        guard let tqv = library.makeFunction(name: "texQuad_v"),
              let tqf = library.makeFunction(name: "texQuad_f")
        else { throw RenderError.makeFunction }
        let texQuadVD = Renderer.makeTexQuadVertexDescriptor()
        let texQuadPD = MTLRenderPipelineDescriptor()
        texQuadPD.vertexFunction = tqv
        texQuadPD.fragmentFunction = tqf
        texQuadPD.vertexDescriptor = texQuadVD
        texQuadPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        texQuadPD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(texQuadPD.colorAttachments[0])
        self.texQuadPipeline = try device.makeRenderPipelineState(descriptor: texQuadPD)

        // Background-image pipeline: fullscreen screen-space NDC quad that
        // samples the loaded image texture. Depth-tested (always-pass state is
        // set at draw time) so it composites as the backdrop.
        let bgVD = Renderer.makeBgQuadVertexDescriptor()
        let bgPD = MTLRenderPipelineDescriptor()
        bgPD.vertexFunction = bgv
        bgPD.fragmentFunction = bgf
        bgPD.vertexDescriptor = bgVD
        bgPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        bgPD.depthAttachmentPixelFormat = depthPixelFormat
        Renderer.enableAlphaBlending(bgPD.colorAttachments[0])
        self.bgImagePipeline = try device.makeRenderPipelineState(descriptor: bgPD)

        // Anaglyph merge pipeline: combines two eye textures via per-channel
        // masks. Screen-space NDC quad, no depth test.
        let mergeVD = Renderer.makeBgQuadVertexDescriptor()
        let mergePD = MTLRenderPipelineDescriptor()
        mergePD.vertexFunction = mgv
        mergePD.fragmentFunction = mgf
        mergePD.vertexDescriptor = mergeVD
        mergePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        mergePD.depthAttachmentPixelFormat = depthPixelFormat
        self.mergePipeline = try device.makeRenderPipelineState(descriptor: mergePD)

        // Linear/clamp sampler for slice/color-plane textures.
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw RenderError.makeBuffer
        }
        self.texQuadSampler = sampler

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
            let qvb = Renderer.makeQuadBuffer(device),
            let bqb = Renderer.makeBgQuadBuffer(device)
        else { throw RenderError.makeBuffer }
        self.sphereVB = svb
        self.sphereIB = sib
        self.cylinderVB = cvb
        self.cylinderIB = cib
        self.coneVB = gvb
        self.coneIB = gib
        self.quadVB = qvb
        self.bgQuadVB = bqb
        self.overlayDepthState = Renderer.makeOverlayDepthState(device: device)
        self.depthStencilState = Renderer.makeDepthStencilState(device: device)
        // Transparent depth state: less-equal compare with NO depth write. Lets
        // transparent objects composite back-to-front without occluding each
        // other via the depth buffer (which would drop later fragments).
        self.transparentDepthState = Renderer.makeTransparentDepthState(device: device)
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

    /// Depth state for transparent objects: less-equal compare (so a transparent
    /// fragment still shows through opaque geometry in front of it) with depth
    /// writes disabled (so transparent fragments don't occlude each other, letting
    /// back-to-front blending composite them correctly).
    private static func makeTransparentDepthState(device: MTLDevice) -> MTLDepthStencilState? {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .lessEqual
        d.isDepthWriteEnabled = false
        return device.makeDepthStencilState(descriptor: d)
    }

    /// Enable standard alpha blending on a pipeline color attachment. When the
    /// fragment alpha is 1.0 (the default), the blend result is identical to opaque
    /// rendering, so existing output is preserved. Used for scene-object transparency.
    private static func enableAlphaBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

        // Background color for depth cueing: derive from the scene background so
        // distant fragments fade toward what's already drawn.
        let bgColor: SIMD3<Float>
        if let override = clearColorOverride {
            bgColor = SIMD3<Float>(Float(override.red), Float(override.green), Float(override.blue))
        } else if scene.backgroundType == .gradient_top {
            bgColor = Renderer.float3FromHex(scene.backgroundBottom)
        } else {
            bgColor = Renderer.float3FromHex(scene.background)
        }
        // Depth-cueing range from the framing sphere.
        let sceneRadius = scene.boundingSphereRadius()
        let camDist = simd_length(cam.eyePosition() - sceneCentroid())
        let fogNear = max(0.1, camDist - sceneRadius * 1.5)
        let fogFar = camDist + sceneRadius * 2.0
        var frame = Renderer.makeFrame(view: cam.viewMatrix(),
                                       proj: cam.projectionMatrix(aspect: aspect),
                                       lighting: scene.lighting,
                                       eye: cam.eyePosition(),
                                       backgroundColor: bgColor)
        frame.lineWidth = scene.lineWidth
        frame.opacity = scene.opacity
        frame.depthCueingStrength = scene.depthCueingStrength
        frame.fogNear = fogNear
        frame.fogFar = fogFar
        frame.aoStrength = scene.aoStrength
        frame.shadowStrength = scene.shadowStrength
        // Multi-light rig: when configured, override the single-light direction
        // with the brightest enabled light (intensity scales the diffuse term).
        if let light = multiLightDir(view: cam.viewMatrix()) {
            frame.lightDir = light.dir
            frame.diffuse = min(scene.lighting.diffuse * light.intensity, 1.0)
        }
        // Sync the world-space light direction for the AO/shadow cache key.
        currentLightDir = frame.lightDir
        if !Renderer.forceNextBufferAllocationSuccess {
            Renderer.forceNextBufferAllocationSuccess = true
            return false
        }
        guard let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }

        // Resolve the effective MSAA count: the explicit runtime/export override
        // (`msaaSampleCount`) when set, otherwise the scene's configured count,
        // resolved to the highest device-supported value <= the request among
        // 8/4/2/1. A count of 1 preserves the exact original single-sample path
        // below; >1 routes through the MSAA resolve path.
        let effectiveCount = effectiveMSAACount

        // Anaglyph stereo: render the scene twice from offset eye cameras and
        // merge via per-channel masks. Off by default, so existing rendering is
        // byte-identical. The anaglyph path is fully self-contained here.
        if scene.anaglyphMode != .off {
            return encodeAnaglyph(to: commandBuffer, target: target, viewport: viewport,
                                  cam: cam, w: w, h: h, effectiveCount: effectiveCount)
        }
        if effectiveCount > 1 {
            return encodeMSAA(to: commandBuffer, target: target, viewport: viewport,
                              cam: cam, frameBuffer: frameBuffer, w: w, h: h,
                              sampleCount: effectiveCount)
        }

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

        guard drawScene(enc: enc, frameBuffer: frameBuffer, w: w, h: h, cam: cam) else { enc.endEncoding(); return false }

        enc.endEncoding()
        return true
    }

    /// Shared draw sequence for both the single-sample and MSAA paths. Kept in
    /// one place so the two paths produce identical scene content — only the
    /// render target, resolve, and pipeline sample counts differ.
    @discardableResult
    private func drawScene(enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?,
                           w: Int, h: Int, cam: Camera) -> Bool {
        // Rebuild shared sphere/cylinder geometry if the tessellation factor
        // changed (no-op when unchanged, so this is cheap every frame).
        rebuildGeometryIfNeeded()

        // Structure-cull flags for this frame (display-only; empty in 2D or when
        // no clip plane is active). Computed once and shared by the draw paths.
        frameStructureCull = scene.displayMode.is2D ? [] : structureCullFlags()
        // Translational-asymmetric-unit filter: with no supercell, keep only atoms
        // whose fractional coords lie inside the base cell.
        if scene.repetitionMode == .asymmetricUnit,
           scene.superCell.total <= 1, let cell = scene.cell {
            let eps: Float = 1e-4
            frameRepetitionCull = scene.atoms.map { a in
                guard let f = scene.fractionalCoord(a.coord),
                      f.x.isFinite, f.y.isFinite, f.z.isFinite else { return true }
                return f.x < -eps || f.x > 1 - eps || f.y < -eps || f.y > 1 - eps || f.z < -eps || f.z > 1 - eps
            }
        } else {
            frameRepetitionCull = []
        }

        // Image backdrop: drawn FIRST, before all geometry, with no depth
        // write so it sits behind everything. Suppressed during exports with an
        // explicit clearColorOverride. Falls back silently to solid/gradient on
        // any load failure (currentBackgroundImageTexture returns nil).
        if scene.backgroundType == .image && clearColorOverride == nil,
           let tex = currentBackgroundImageTexture() {
            drawBackgroundImage(enc, texture: tex, w: w, h: h)
        }

        // Vertical-gradient backdrop. Suppressed during exports with an explicit
        // clearColorOverride so transparent/custom backgrounds render as configured.
        if scene.backgroundType == .gradient_top && clearColorOverride == nil {
            drawGradient(enc)
        }

        // The atomic structure (atoms/bonds/polyhedra) can be hidden so the user
        // can focus on the cell frame, axes, or Brillouin-zone overlay. The
        // frame/axes/BZ branches below draw regardless.
        if scene.showStructure {
            // Translucent ordering (finding 6): when the structure itself is
            // transparent, draw the molecular surface FIRST so the unified
            // back-to-front atom/bond pass alpha-overs it correctly. (The surface
            // is a single bulk mesh, so it can't share the per-atom blend queue;
            // drawing it first is the pragmatic approximation.)
            if scene.opacity < 1.0, !scene.displayMode.is2D {
                guard drawMolecularSurface(enc, frameBuffer: frameBuffer) else { return false }
            }
            if scene.displayMode.is2D {
                // Transparent 2D: disable depth writes so flat atoms/bonds blend.
                if scene.opacity < 1.0, let tds = transparentDepthState {
                    enc.setDepthStencilState(tds)
                    defer { enc.setDepthStencilState(depthStencilState) }
                    guard drawAtoms2D(enc, frameBuffer: frameBuffer, w: w, h: h) else { return false }
                    guard drawBonds2D(enc, frameBuffer: frameBuffer) else { return false }
                } else {
                    guard drawAtoms2D(enc, frameBuffer: frameBuffer, w: w, h: h) else { return false }
                    guard drawBonds2D(enc, frameBuffer: frameBuffer) else { return false }
                }
            } else if scene.displayMode == .polyhedral {
                // Transparent polyhedra: sort cells back-to-front by centroid
                // depth and disable depth writes so blending composites correctly.
                if scene.opacity < 1.0 {
                    guard drawPolyhedralTransparent(enc: enc, frameBuffer: frameBuffer) else { return false }
                } else {
                    guard drawPolyhedral(enc, frameBuffer: frameBuffer) else { return false }
                }
            } else if scene.opacity < 1.0 {
                // Transparent path: unified back-to-front sorting across atoms
                // and bonds with depth writes disabled, so blending composites
                // correctly regardless of draw order.
                guard drawTransparentStructure(enc: enc, frameBuffer: frameBuffer) else { return false }
            } else {
                guard drawAtoms(enc, frameBuffer: frameBuffer) else { return false }
                guard drawBonds(enc, frameBuffer: frameBuffer) else { return false }
            }
            if !scene.displayMode.is2D {
                guard drawForceArrows(enc, frameBuffer: frameBuffer) else { return false }
            }
            // Displacement arrows draw in every display mode (including 2D)
            // using the shared line pipeline; still gated by showStructure above.
            guard drawDisplacementArrows(enc, frameBuffer: frameBuffer) else { return false }
            guard drawTrajectoryTrails(enc, frameBuffer: frameBuffer) else { return false }
            if !scene.displayMode.is2D {
                guard drawHbonds(enc, frameBuffer: frameBuffer) else { return false }
            }
        }

        // Opaque-case surface draw. The transparent case is handled at the top of
        // the showStructure block (drawn before the structure) so it isn't drawn
        // twice. Hide with `showStructure` off and skip in 2D modes.
        if scene.showStructure && scene.opacity >= 1.0, !scene.displayMode.is2D {
            guard drawMolecularSurface(enc, frameBuffer: frameBuffer) else { return false }
        }

        guard drawCell(enc, frameBuffer: frameBuffer) else { return false }

        if scene.showBrillouinZone {
            guard drawBrillouinZone(enc, frameBuffer: frameBuffer) else { return false }
        }

        guard drawIsosurface(enc, frameBuffer: frameBuffer) else { return false }
        guard drawFermiSurface(enc, frameBuffer: frameBuffer) else { return false }

        // Volume slices: textured quads composited with structure via depth testing.
        guard drawVolumeSlices(enc, frameBuffer: frameBuffer) else { return false }

        // Color-plane compositing: 2D grid as a textured quad in the 3D scene
        // (replaces the old fullscreen canvas swap). Drawn after slices so it sits
        // on top if overlapping.
        guard drawColorPlane3D(enc, frameBuffer: frameBuffer) else { return false }

        if scene.showAxes {
            guard drawOrientationGizmo(enc, camera: cam, w: w, h: h) else { return false }
        }

        guard drawMeasurements(enc, frameBuffer: frameBuffer) else { return false }
        return true
    }

    /// MSAA render path: render into a private multisample color texture and
    /// resolve into the caller's single-sample target. The depth texture and
    /// all pipelines match the effective sample count.
    @discardableResult
    private func encodeMSAA(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                            viewport: MTLViewport, cam: Camera, frameBuffer: MTLBuffer,
                            w: Int, h: Int, sampleCount: Int) -> Bool {
        // Lazily build (and cache) MSAA pipelines for this sample count. Failure
        // here is an allocation failure — surface it as a failed encode.
        guard makeMSAAPipelines(sampleCount: sampleCount) else { return false }
        let pipelines = msaaPipelineCache[sampleCount]!

        // Cache-bounded multisample color + depth attachments keyed by dimensions
        // and sample count. Allocation failure surfaces as a failed encode.
        guard let msaaColor = ensureMSAAColorTexture(width: w, height: h, sampleCount: sampleCount) else { return false }
        guard let msaaDepth = ensureMSAADepthTexture(width: w, height: h, sampleCount: sampleCount) else { return false }

        // Swap the active pipelines to the MSAA variants for the duration of this
        // encode, then restore the originals. The shared drawScene() references
        // the ivars directly, so it transparently uses the MSAA pipelines.
        let saved = (atomPipeline, linePipeline, flat2DPipeline, polyPipeline, gradPipeline, thickLinePipeline, texQuadPipeline, bgImagePipeline)
        defer { atomPipeline = saved.0; linePipeline = saved.1; flat2DPipeline = saved.2; polyPipeline = saved.3; gradPipeline = saved.4; thickLinePipeline = saved.5; texQuadPipeline = saved.6; bgImagePipeline = saved.7 }
        atomPipeline = pipelines.atom
        linePipeline = pipelines.line
        flat2DPipeline = pipelines.flat2D
        polyPipeline = pipelines.poly
        gradPipeline = pipelines.grad
        thickLinePipeline = pipelines.thickLine
        texQuadPipeline = pipelines.texQuad
        bgImagePipeline = pipelines.bgImage

        let clearColor: MTLClearColor
        if let override = clearColorOverride {
            clearColor = override
        } else {
            clearColor = scene.backgroundType == .gradient_top
                ? Renderer.MTLClearColorFromString(scene.backgroundBottom)
                : Renderer.MTLClearColorFromString(scene.background)
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = msaaColor
        desc.colorAttachments[0].resolveTexture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .multisampleResolve
        desc.colorAttachments[0].clearColor = clearColor
        desc.depthAttachment.texture = msaaDepth
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = .dontCare
        desc.depthAttachment.clearDepth = 1.0

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return false }
        enc.setViewport(viewport)
        enc.setCullMode(.none)
        guard let depthStencilState else { enc.endEncoding(); return false }
        enc.setDepthStencilState(depthStencilState)

        guard drawScene(enc: enc, frameBuffer: frameBuffer, w: w, h: h, cam: cam) else { enc.endEncoding(); return false }

        enc.endEncoding()
        return true
    }

    // MARK: - Anaglyph stereo rendering

    /// Deterministic eye separation for anaglyph rendering: a fixed fraction of
    /// the scene's bounding-sphere radius, clamped to a sane range. Returns 0
    /// for an empty scene (caller falls back to single-view render).
    private func anaglyphEyeSeparation() -> Float {
        let r = scene.boundingSphereRadius()
        guard r > 1e-6 else { return 0 }
        let sep = r * 0.03
        return min(5.0, max(0.5, sep))
    }

    /// The camera's lateral (right) axis in world space. The view matrix is
    /// R^T * translate(-eye), so the camera's right direction is the first
    /// column of the rotation matrix R.
    private func cameraRightAxis(_ cam: Camera) -> SIMD3<Float> {
        let r = float4x4(cam.rotation)
        return SIMD3<Float>(r[0][0], r[1][0], r[2][0])
    }

    /// Build an eye camera by shifting the orbit center along the camera's
    /// lateral axis. Shifting the center (not just the eye) produces the
    /// parallax effect while keeping the orbit target consistent.
    private func anaglyphEyeCamera(_ cam: Camera, offset: Float) -> Camera {
        var eye = cam
        let right = cameraRightAxis(cam)
        eye.center = cam.center + right * offset
        return eye
    }

    /// Render one anaglyph eye into the given single-sample target texture.
    /// Handles both the single-sample and MSAA-resolve paths transparently.
    private func renderAnaglyphEye(to target: MTLTexture, commandBuffer: MTLCommandBuffer,
                                   viewport: MTLViewport, cam: Camera,
                                   w: Int, h: Int, clearColor: MTLClearColor,
                                   sampleCount: Int) -> Bool {
        // Build the per-eye frame buffer.
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0
        let bgColor: SIMD3<Float>
        if let override = clearColorOverride {
            bgColor = SIMD3<Float>(Float(override.red), Float(override.green), Float(override.blue))
        } else if scene.backgroundType == .gradient_top {
            bgColor = Renderer.float3FromHex(scene.backgroundBottom)
        } else {
            bgColor = Renderer.float3FromHex(scene.background)
        }
        let sceneRadius = scene.boundingSphereRadius()
        let camDist = simd_length(cam.eyePosition() - sceneCentroid())
        let fogNear = max(0.1, camDist - sceneRadius * 1.5)
        let fogFar = camDist + sceneRadius * 2.0
        var frame = Renderer.makeFrame(view: cam.viewMatrix(),
                                       proj: cam.projectionMatrix(aspect: aspect),
                                       lighting: scene.lighting,
                                       eye: cam.eyePosition(),
                                       backgroundColor: bgColor)
        frame.lineWidth = scene.lineWidth
        frame.opacity = scene.opacity
        frame.depthCueingStrength = scene.depthCueingStrength
        frame.fogNear = fogNear
        frame.fogFar = fogFar
        frame.aoStrength = scene.aoStrength
        frame.shadowStrength = scene.shadowStrength
        if let light = multiLightDir(view: cam.viewMatrix()) {
            frame.lightDir = light.dir
            frame.diffuse = min(scene.lighting.diffuse * light.intensity, 1.0)
        }
        guard let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }

        if sampleCount > 1 {
            return renderAnaglyphEyeMSAA(to: target, commandBuffer: commandBuffer,
                                          viewport: viewport, cam: cam,
                                          frameBuffer: frameBuffer, w: w, h: h,
                                          clearColor: clearColor, sampleCount: sampleCount)
        }

        guard ensureDepthTexture(width: w, height: h) else { return false }
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
        guard let depthStencilState else { enc.endEncoding(); return false }
        enc.setDepthStencilState(depthStencilState)
        // Draw the background image (if any) into the eye texture too, so the
        // merge step composites a consistent backdrop for both eyes.
        if scene.backgroundType == .image && clearColorOverride == nil,
           let tex = currentBackgroundImageTexture() {
            drawBackgroundImage(enc, texture: tex, w: w, h: h)
        }
        guard drawScene(enc: enc, frameBuffer: frameBuffer, w: w, h: h, cam: cam) else { enc.endEncoding(); return false }
        enc.endEncoding()
        return true
    }

    /// MSAA variant of the anaglyph eye render: render into a multisample
    /// texture and resolve into the single-sample eye target.
    private func renderAnaglyphEyeMSAA(to target: MTLTexture, commandBuffer: MTLCommandBuffer,
                                        viewport: MTLViewport, cam: Camera,
                                        frameBuffer: MTLBuffer, w: Int, h: Int,
                                        clearColor: MTLClearColor, sampleCount: Int) -> Bool {
        guard makeMSAAPipelines(sampleCount: sampleCount) else { return false }
        let pipelines = msaaPipelineCache[sampleCount]!
        guard let msaaColor = ensureMSAAColorTexture(width: w, height: h, sampleCount: sampleCount) else { return false }
        guard let msaaDepth = ensureMSAADepthTexture(width: w, height: h, sampleCount: sampleCount) else { return false }
        let saved = (atomPipeline, linePipeline, flat2DPipeline, polyPipeline, gradPipeline, thickLinePipeline, texQuadPipeline, bgImagePipeline)
        defer { atomPipeline = saved.0; linePipeline = saved.1; flat2DPipeline = saved.2; polyPipeline = saved.3; gradPipeline = saved.4; thickLinePipeline = saved.5; texQuadPipeline = saved.6; bgImagePipeline = saved.7 }
        atomPipeline = pipelines.atom
        linePipeline = pipelines.line
        flat2DPipeline = pipelines.flat2D
        polyPipeline = pipelines.poly
        gradPipeline = pipelines.grad
        thickLinePipeline = pipelines.thickLine
        texQuadPipeline = pipelines.texQuad
        bgImagePipeline = pipelines.bgImage

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = msaaColor
        desc.colorAttachments[0].resolveTexture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .multisampleResolve
        desc.colorAttachments[0].clearColor = clearColor
        desc.depthAttachment.texture = msaaDepth
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = .dontCare
        desc.depthAttachment.clearDepth = 1.0

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return false }
        enc.setViewport(viewport)
        enc.setCullMode(.none)
        guard let depthStencilState else { enc.endEncoding(); return false }
        enc.setDepthStencilState(depthStencilState)
        if scene.backgroundType == .image && clearColorOverride == nil,
           let tex = currentBackgroundImageTexture() {
            drawBackgroundImage(enc, texture: tex, w: w, h: h)
        }
        guard drawScene(enc: enc, frameBuffer: frameBuffer, w: w, h: h, cam: cam) else { enc.endEncoding(); return false }
        enc.endEncoding()
        return true
    }

    /// Ensure the intermediate single-sample anaglyph eye textures exist and
    /// match the target size. Recreated when dimensions change.
    private func ensureEyeTextures(w: Int, h: Int) -> Bool {
        if eyeTextureSize.w == w, eyeTextureSize.h == h,
           leftEyeTexture != nil, rightEyeTexture != nil { return true }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w
        desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let left = device.makeTexture(descriptor: desc),
              let right = device.makeTexture(descriptor: desc) else { return false }
        leftEyeTexture = left
        rightEyeTexture = right
        eyeTextureSize = (w, h)
        return true
    }

    /// Top-level anaglyph encode: render both eyes, then merge into the target.
    @discardableResult
    private func encodeAnaglyph(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                                viewport: MTLViewport, cam: Camera,
                                w: Int, h: Int, effectiveCount: Int) -> Bool {
        // Fall back to single-view render if the scene is empty, the camera is
        // invalid, or the geometry is degenerate (no meaningful parallax).
        let sep = anaglyphEyeSeparation()
        guard sep > 0, !scene.atoms.isEmpty else {
            // Re-enter the normal single-view path with the original camera.
            // Build a minimal frame and reuse the single-sample/MSAA path by
            // temporarily disabling anaglyph.
            let saved = scene.anaglyphMode
            scene.anaglyphMode = .off
            defer { scene.anaglyphMode = saved }
            return encodeAnaglyphFallback(to: commandBuffer, target: target, viewport: viewport,
                                          cam: cam, w: w, h: h, effectiveCount: effectiveCount)
        }

        guard ensureEyeTextures(w: w, h: h) else { return false }

        let clearColor: MTLClearColor
        if let override = clearColorOverride {
            clearColor = override
        } else {
            clearColor = scene.backgroundType == .gradient_top
                ? Renderer.MTLClearColorFromString(scene.backgroundBottom)
                : Renderer.MTLClearColorFromString(scene.background)
        }

        let leftCam = anaglyphEyeCamera(cam, offset: -sep / 2)
        let rightCam = anaglyphEyeCamera(cam, offset: sep / 2)

        guard let leftTarget = leftEyeTexture, let rightTarget = rightEyeTexture else { return false }
        guard renderAnaglyphEye(to: leftTarget, commandBuffer: commandBuffer,
                                viewport: viewport, cam: leftCam,
                                w: w, h: h, clearColor: clearColor,
                                sampleCount: effectiveCount) else { return false }
        guard renderAnaglyphEye(to: rightTarget, commandBuffer: commandBuffer,
                                viewport: viewport, cam: rightCam,
                                w: w, h: h, clearColor: clearColor,
                                sampleCount: effectiveCount) else { return false }

        return mergeAnaglyph(to: target, commandBuffer: commandBuffer,
                             viewport: viewport, w: w, h: h)
    }

    /// Fallback single-view render for anaglyph when the scene is empty or
    /// geometry is degenerate. Re-runs the normal encode path with anaglyph
    /// temporarily disabled.
    private func encodeAnaglyphFallback(to commandBuffer: MTLCommandBuffer, target: MTLTexture,
                                        viewport: MTLViewport, cam: Camera,
                                        w: Int, h: Int, effectiveCount: Int) -> Bool {
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0
        let bgColor: SIMD3<Float>
        if let override = clearColorOverride {
            bgColor = SIMD3<Float>(Float(override.red), Float(override.green), Float(override.blue))
        } else if scene.backgroundType == .gradient_top {
            bgColor = Renderer.float3FromHex(scene.backgroundBottom)
        } else {
            bgColor = Renderer.float3FromHex(scene.background)
        }
        let sceneRadius = scene.boundingSphereRadius()
        let camDist = simd_length(cam.eyePosition() - sceneCentroid())
        let fogNear = max(0.1, camDist - sceneRadius * 1.5)
        let fogFar = camDist + sceneRadius * 2.0
        var frame = Renderer.makeFrame(view: cam.viewMatrix(),
                                       proj: cam.projectionMatrix(aspect: aspect),
                                       lighting: scene.lighting,
                                       eye: cam.eyePosition(),
                                       backgroundColor: bgColor)
        frame.lineWidth = scene.lineWidth
        frame.opacity = scene.opacity
        frame.depthCueingStrength = scene.depthCueingStrength
        frame.fogNear = fogNear
        frame.fogFar = fogFar
        frame.aoStrength = scene.aoStrength
        frame.shadowStrength = scene.shadowStrength
        if let light = multiLightDir(view: cam.viewMatrix()) {
            frame.lightDir = light.dir
            frame.diffuse = min(scene.lighting.diffuse * light.intensity, 1.0)
        }
        guard let frameBuffer = device.makeBuffer(bytes: &frame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        if effectiveCount > 1 {
            return encodeMSAA(to: commandBuffer, target: target, viewport: viewport,
                              cam: cam, frameBuffer: frameBuffer, w: w, h: h,
                              sampleCount: effectiveCount)
        }
        guard ensureDepthTexture(width: w, height: h) else { return false }
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
        guard let depthStencilState else { enc.endEncoding(); return false }
        enc.setDepthStencilState(depthStencilState)
        guard drawScene(enc: enc, frameBuffer: frameBuffer, w: w, h: h, cam: cam) else { enc.endEncoding(); return false }
        enc.endEncoding()
        return true
    }

    /// Merge the two anaglyph eye textures into the final target using the
    /// per-channel masks for the current anaglyph mode.
    private func mergeAnaglyph(to target: MTLTexture, commandBuffer: MTLCommandBuffer,
                               viewport: MTLViewport, w: Int, h: Int) -> Bool {
        guard let left = leftEyeTexture, let right = rightEyeTexture else { return false }
        let masks = AnaglyphChannelMasks.forMode(scene.anaglyphMode)
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return false }
        enc.setViewport(viewport)
        enc.setRenderPipelineState(mergePipeline)
        enc.setVertexBuffer(bgQuadVB, offset: 0, index: 0)
        enc.setFragmentTexture(left, index: 0)
        enc.setFragmentTexture(right, index: 1)
        enc.setFragmentSamplerState(texQuadSampler, index: 0)
        var leftMask = SIMD4<Float>(masks.left.x, masks.left.y, masks.left.z, 0)
        var rightMask = SIMD4<Float>(masks.right.x, masks.right.y, masks.right.z, 0)
        enc.setFragmentBytes(&leftMask, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setFragmentBytes(&rightMask, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        return true
    }

    // MARK: - Background image rendering

    /// Load (or return the cached) background image texture. Lazily loads from
    /// scene.backgroundImagePath; returns nil on any failure (missing file,
    /// corrupt image, zero size) so the renderer falls back to solid/gradient.
    /// Cached per (path, device); invalidated when the path or device changes.
    private func currentBackgroundImageTexture() -> MTLTexture? {
        let path = scene.backgroundImagePath
        guard let path, !path.isEmpty else {
            // Path nil/empty: clear any stale cache.
            cachedBgImageTexture = nil
            cachedBgImagePath = nil
            return nil
        }
        if cachedBgImagePath == path, cachedBgImageDevice === device, let tex = cachedBgImageTexture {
            return tex
        }
        // Path changed or first load: attempt to load.
        guard let tex = Renderer.loadBackgroundImage(path: path, device: device) else {
            cachedBgImageTexture = nil
            cachedBgImagePath = nil
            return nil
        }
        cachedBgImageTexture = tex
        cachedBgImagePath = path
        cachedBgImageDevice = device
        return tex
    }

    /// Maximum decoded background image dimension (px). Caps memory use
    /// (RGBA8 = w*h*4 bytes) and keeps the texture within Metal's size limits;
    /// a large photo can otherwise allocate hundreds of MB.
    static let backgroundMaxDimension = 4096

    /// Return a CGImage whose largest dimension is at most `maxDimension`,
    /// downsampled aspect-preserving when either original dimension exceeds the
    /// cap (the largest dimension becomes exactly maxDimension), returned unchanged
    /// when within the cap, or nil on any failure.
    static func cappedBackgroundImage(_ cgImage: CGImage, maxDimension: Int) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0, maxDimension > 0 else { return nil }
        if max(w, h) <= maxDimension {
            return cgImage
        }
        let scale = CGFloat(maxDimension) / CGFloat(max(w, h))
        let newW = max(1, Int(CGFloat(w) * scale))
        let newH = max(1, Int(CGFloat(h) * scale))
        let bytesPerRow = newW * 4
        var pixels = [UInt8](repeating: 0, count: newH * bytesPerRow)
        guard let context = CGContext(data: &pixels, width: newW, height: newH,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage()
    }

    /// Load an image file into an MTLPixelFormat .rgba8Unorm texture. Returns
    /// nil on any failure (file missing, unreadable, zero dimensions, decode
    /// error). Never throws — the renderer must never crash on a bad image.
    private static func loadBackgroundImage(path: String, device: MTLDevice) -> MTLTexture? {
        let url = URL(fileURLWithPath: path)
        if let dataProvider = CGDataProvider(filename: url.path),
           let cg = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                ?? CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
           let capped = Renderer.cappedBackgroundImage(cg, maxDimension: Renderer.backgroundMaxDimension) {
            return cgImageToTexture(capped, device: device)
        }
        // Fallback for other formats (tiff, bmp, etc.).
        if let nsImage = NSImage(contentsOf: url), let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let capped = Renderer.cappedBackgroundImage(cg, maxDimension: Renderer.backgroundMaxDimension) {
            return cgImageToTexture(capped, device: device)
        }
        return nil
    }

    /// Convert a CGImage to an RGBA8 MTLTexture. Returns nil on failure.
    private static func cgImageToTexture(_ cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        // Belt-and-braces: width is capped at backgroundMaxDimension (4096),
        // so this product cannot overflow, but guard the allocation count anyway.
        guard bytesPerRow > 0, height > 0, bytesPerRow <= Int.max / height else { return nil }
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = width
        desc.height = height
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: bytesPerRow)
        return tex
    }

    /// Draw the background image as a fullscreen scale-to-cover quad FIRST
    /// (before all other geometry, no depth write). Uses the screen-space
    /// bgImage pipeline. The uv mapping implements scale-to-cover: the image
    /// fills the frame, cropping overflow, centered.
    private func drawBackgroundImage(_ enc: MTLRenderCommandEncoder, texture: MTLTexture, w: Int, h: Int) {
        enc.setDepthStencilState(overlayDepthState)          // always-pass, never-write
        enc.setRenderPipelineState(bgImagePipeline)
        // Scale-to-cover uv mapping: compute the crop so the image fills the
        // viewport, centered, cropping the overflow.
        let imgAspect = Float(texture.width) / Float(texture.height)
        let viewAspect = (h > 0) ? Float(w) / Float(h) : 1.0
        var u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1
        if imgAspect > viewAspect {
            // Image wider than view: crop left/right.
            let crop = viewAspect / imgAspect
            u0 = (1.0 - crop) * 0.5
            u1 = u0 + crop
        } else {
            // Image taller than view: crop top/bottom.
            let crop = imgAspect / viewAspect
            v0 = (1.0 - crop) * 0.5
            v1 = v0 + crop
        }
        struct V { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
        let key = (imgW: texture.width, imgH: texture.height, viewW: w, viewH: h)
        if cachedBgQuadKey != key || cachedBgQuadBuffer == nil {
            let newVerts: [V] = [
                V(pos: SIMD2(-1, -1), uv: SIMD2(u0, v1)),
                V(pos: SIMD2( 1, -1), uv: SIMD2(u1, v1)),
                V(pos: SIMD2(-1,  1), uv: SIMD2(u0, v0)),
                V(pos: SIMD2(-1,  1), uv: SIMD2(u0, v0)),
                V(pos: SIMD2( 1, -1), uv: SIMD2(u1, v1)),
                V(pos: SIMD2( 1,  1), uv: SIMD2(u1, v0)),
            ]
            if let buf = device.makeBuffer(bytes: newVerts, length: newVerts.count * MemoryLayout<V>.stride, options: []) {
                cachedBgQuadBuffer = buf
                cachedBgQuadKey = key
            } else {
                return
            }
        }
        guard let vb = cachedBgQuadBuffer else { return }
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(texQuadSampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.setDepthStencilState(depthStencilState)           // restore for the scene
    }

    /// Resolve a requested MSAA count to the highest device-supported value
    /// <= the request among 8/4/2/1. A request <= 1 short-circuits to 1.
    private func resolveMSAACount(_ requested: Int) -> Int {
        guard requested > 1 else { return 1 }
        for count in [8, 4, 2] {
            if count <= requested && device.supportsTextureSampleCount(count) {
                return count
            }
        }
        return 1
    }

    /// Lazily build and cache MSAA pipelines for the given sample count. Returns
    /// false if any pipeline cannot be created (surfaces as an encode failure).
    private func makeMSAAPipelines(sampleCount: Int) -> Bool {
        if msaaPipelineCache[sampleCount] != nil { return true }
        guard
            let v = library.makeFunction(name: "v_main"),
            let f = library.makeFunction(name: "f_main"),
            let lv = library.makeFunction(name: "lv_main"),
            let lf = library.makeFunction(name: "lf_main"),
            let f2v = library.makeFunction(name: "flat2D_v"),
            let f2f = library.makeFunction(name: "flat2D_f"),
            let pv = library.makeFunction(name: "poly_v"),
            let pf = library.makeFunction(name: "poly_f"),
            let gv = library.makeFunction(name: "grad_v"),
            let gf = library.makeFunction(name: "grad_f"),
            let tlv = library.makeFunction(name: "thickLine_v"),
            let tlf = library.makeFunction(name: "thickLine_f"),
            let tqv = library.makeFunction(name: "texQuad_v"),
            let tqf = library.makeFunction(name: "texQuad_f"),
            let bgv = library.makeFunction(name: "bgImage_v"),
            let bgf = library.makeFunction(name: "bgImage_f")
        else { return false }

        func pipeline(vertex: MTLFunction, fragment: MTLFunction, vd: MTLVertexDescriptor,
                     blend: Bool = false) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vertex
            pd.fragmentFunction = fragment
            pd.vertexDescriptor = vd
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm
            pd.rasterSampleCount = sampleCount
            pd.depthAttachmentPixelFormat = depthPixelFormat
            if blend { Renderer.enableAlphaBlending(pd.colorAttachments[0]) }
            return try? device.makeRenderPipelineState(descriptor: pd)
        }

        guard let atom = pipeline(vertex: v, fragment: f, vd: Renderer.makeAtomVertexDescriptor(), blend: true),
              let line = pipeline(vertex: lv, fragment: lf, vd: Renderer.makeLineVertexDescriptor(), blend: true),
              let flat2D = pipeline(vertex: f2v, fragment: f2f, vd: Renderer.makeFlat2DVertexDescriptor(), blend: true),
              let poly = pipeline(vertex: pv, fragment: pf, vd: Renderer.makePolyVertexDescriptor(), blend: true),
              let grad = pipeline(vertex: gv, fragment: gf, vd: Renderer.makeGradVertexDescriptor()),
              let thickLine = pipeline(vertex: tlv, fragment: tlf, vd: Renderer.makeLineVertexDescriptor(), blend: true),
              let texQuad = pipeline(vertex: tqv, fragment: tqf, vd: Renderer.makeTexQuadVertexDescriptor(), blend: true),
              let bgImage = pipeline(vertex: bgv, fragment: bgf, vd: Renderer.makeBgQuadVertexDescriptor(), blend: true)
        else { return false }

        // Background-image pipeline is included so the MSAA + background-image path
        // draws with a pipeline whose rasterSampleCount matches the resolve target.
        msaaPipelineCache[sampleCount] = (atom: atom, line: line, flat2D: flat2D, poly: poly, grad: grad, thickLine: thickLine, texQuad: texQuad, bgImage: bgImage)
        return true
    }

    /// Cache-bounded multisample color attachment (private, type2DMultisample).
    /// Recreated only when the dimensions or sample count change.
    private func ensureMSAAColorTexture(width: Int, height: Int, sampleCount: Int) -> MTLTexture? {
        if msaaColorTextureKey == (width, height, sampleCount), let tex = msaaColorTexture {
            return tex
        }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = width
        desc.height = height
        desc.usage = .renderTarget
        desc.storageMode = .private
        desc.textureType = .type2DMultisample
        desc.sampleCount = sampleCount
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        msaaColorTexture = tex
        msaaColorTextureKey = (width, height, sampleCount)
        return tex
    }

    /// Cache-bounded multisample depth attachment (private, type2DMultisample)
    /// matching the effective sample count.
    private func ensureMSAADepthTexture(width: Int, height: Int, sampleCount: Int) -> MTLTexture? {
        if msaaDepthTextureKey == (width, height, sampleCount), let tex = msaaDepthTexture {
            return tex
        }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = depthPixelFormat
        desc.width = width
        desc.height = height
        desc.usage = .renderTarget
        desc.storageMode = .private
        desc.textureType = .type2DMultisample
        desc.sampleCount = sampleCount
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        msaaDepthTexture = tex
        msaaDepthTextureKey = (width, height, sampleCount)
        return tex
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

    /// Per-atom AO/shadow factors from neighbor geometry. Bounded deterministic
    /// approximations using uniform spatial bins. Returns unity immediately when
    /// both effects are disabled (strength 0). Enforces global + per-atom caps
    /// so it never hangs at the supercell limit.
    private var cachedAOShadowFactors: (ao: [Float], shadow: [Float])? = nil
    private var cachedAOShadowKey: (atoms: Int, coords: [SIMD3<Float>], aoQuality: Int,
                                    shadowQuality: Int, aoEnabled: Bool, shadowEnabled: Bool,
                                    lightDir: SIMD3<UInt32>)? = nil
    private static let aoGlobalCap = 50_000   // max atoms analyzed
    private static let aoNeighborCap = 64      // max neighbors per atom
    private func computeAOShadowFactors() -> (ao: [Float], shadow: [Float]) {
        let n = scene.atoms.count
        if n == 0 { return ([], []) }
        // Shortcut based on STRENGTH (what the shader uses), not quality.
        // Default is strength=0, quality=2 -> returns unity immediately.
        if scene.aoStrength == 0 && scene.shadowStrength == 0 {
            // Empty arrays are the unity sentinel used by every draw path.
            return ([], [])
        }
        let coords = scene.atoms.map { $0.coord }
        let lightDir = currentLightDir
        // Cache key: quality affects search radius, light direction affects shadow.
        // Strength is applied in the shader, so it is NOT part of the cache key.
        let aoQuality = max(0, min(3, scene.aoQuality))
        let shadowQuality = max(0, min(3, scene.shadowQuality))
        let lightKey = SIMD3<UInt32>(
            UInt32(((lightDir.x + 1.0) * 0.5) * 1023.0),
            UInt32(((lightDir.y + 1.0) * 0.5) * 1023.0),
            UInt32(((lightDir.z + 1.0) * 0.5) * 1023.0))
        let aoEnabled = scene.aoStrength > 0
        let shadowEnabled = scene.shadowStrength > 0
        if let key = cachedAOShadowKey, key.atoms == n,
           key.aoQuality == aoQuality, key.shadowQuality == shadowQuality,
           key.aoEnabled == aoEnabled, key.shadowEnabled == shadowEnabled,
           key.lightDir == lightKey,
           let cached = cachedAOShadowFactors,
           zip(key.coords, coords).allSatisfy({ $0 == $1 }) {
            return cached
        }
        // Compute search radii only for enabled effects.
        let baseRadius: Float = 3.5
        let aoRadius = scene.aoStrength > 0 ? baseRadius * (0.6 + Float(aoQuality) * 0.4) : 0
        let shadowRadius = scene.shadowStrength > 0 ? baseRadius * (0.6 + Float(shadowQuality) * 0.4) : 0
        let searchRadius = max(aoRadius, shadowRadius)
        var ao = aoEnabled ? [Float](repeating: 1.0, count: n) : []
        var shadow = shadowEnabled ? [Float](repeating: 1.0, count: n) : []

        // Global cap: if exceeded, degrade safely to unity for all atoms.
        if searchRadius > 0 && n <= Self.aoGlobalCap {
            // Bin size = searchRadius guarantees all neighbors are within +/-1 bin,
            // so scanning 27 bins (3x3x3) is sufficient.
            let binSize = searchRadius
            var bmin = coords[0], bmax = coords[0]
            for i in 1..<n {
                bmin = min(bmin, coords[i])
                bmax = max(bmax, coords[i])
            }
            let extent = bmax - bmin + SIMD3<Float>(repeating: 1e-4)
            let binCountX = max(1, min(128, Int(ceil(extent.x / binSize))))
            let binCountY = max(1, min(128, Int(ceil(extent.y / binSize))))
            let binCountZ = max(1, min(128, Int(ceil(extent.z / binSize))))
            let totalBins = binCountX * binCountY * binCountZ
            // Bin heads: index into a linked-list array.
            var binHead = [Int](repeating: -1, count: totalBins)
            var binNext = [Int](repeating: -1, count: n)
            for i in 0..<n {
                let rel = coords[i] - bmin
                let bx = min(binCountX-1, max(0, Int(rel.x / binSize)))
                let by = min(binCountY-1, max(0, Int(rel.y / binSize)))
                let bz = min(binCountZ-1, max(0, Int(rel.z / binSize)))
                let binIndex = bx + binCountX * (by + binCountY * bz)
                binNext[i] = binHead[binIndex]
                binHead[binIndex] = i
            }
            // For each atom, scan the 27 neighboring bins.
            for i in 0..<n {
                let ci = coords[i]
                let rel = ci - bmin
                let bx = min(binCountX-1, max(0, Int(rel.x / binSize)))
                let by = min(binCountY-1, max(0, Int(rel.y / binSize)))
                let bz = min(binCountZ-1, max(0, Int(rel.z / binSize)))
                var aoSum: Float = 0
                var shadowSum: Float = 0
                var candidateChecks = 0
                atomScan: for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            let nx = bx + dx, ny = by + dy, nz = bz + dz
                            if nx < 0 || nx >= binCountX { continue }
                            if ny < 0 || ny >= binCountY { continue }
                            if nz < 0 || nz >= binCountZ { continue }
                            let binIndex = nx + binCountX * (ny + binCountY * nz)
                            var j = binHead[binIndex]
                            while j != -1 {
                                if j != i {
                                    // Candidate cap: count EVERY neighbor examined
                                    // (regardless of effect/distance) so shadow-only
                                    // dense scenes are also bounded.
                                    candidateChecks += 1
                                    if candidateChecks >= Self.aoNeighborCap { break atomScan }
                                    let d = coords[j] - ci
                                    let dist = simd_length(d)
                                    if dist < aoRadius, dist > 1e-5 {
                                        aoSum += 1.0 - dist / aoRadius
                                    }
                                    if dist < shadowRadius, dist > 1e-5 {
                                        let towardLight = simd_dot(d / dist, lightDir)
                                        if towardLight > 0 {
                                            shadowSum += towardLight * (1.0 - dist / shadowRadius)
                                        }
                                    }
                                }
                                j = binNext[j]
                            }
                        }
                    }
                }
                if aoSum > 0 {
                    ao[i] = max(0.15, 1.0 - aoSum * 0.18)
                }
                if shadowSum > 0 {
                    shadow[i] = max(0.15, 1.0 - shadowSum * 0.22)
                }
            }
        }
        // else: n > globalCap -> ao/shadow remain unity (safe degradation)
        cachedAOShadowFactors = (ao, shadow)
        cachedAOShadowKey = (atoms: n, coords: coords, aoQuality: aoQuality,
                             shadowQuality: shadowQuality, aoEnabled: aoEnabled,
                             shadowEnabled: shadowEnabled, lightDir: lightKey)
        return (ao, shadow)
    }

    private func drawAtoms(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let selected = Set(scene.selectedAtoms)
        let aoShadow = computeAOShadowFactors()
        let view = sceneView(frameBuffer)
        var inst: [(depth: Float, data: InstanceData)] = []
        inst.reserveCapacity(scene.atoms.count)
        for (i, a) in scene.atoms.enumerated() {
            // Display-only clip + asymmetric-unit filter.
            if isAtomCulled(i) { continue }
            let radius = atomRadius(z: a.atomicNumber)
            if radius <= 0 { continue }
            let c = atomColor(at: i, selected: selected.contains(i))
            let ao = i < aoShadow.ao.count ? aoShadow.ao[i] : 1.0
            let sh = i < aoShadow.shadow.count ? aoShadow.shadow[i] : 1.0
            let data = InstanceData(model: float4x4(translation: a.coord),
                                    color: SIMD4(c.x, c.y, c.z, 1.0),
                                    radius: radius, metalness: 0.0,
                                    aoFactor: ao, shadowFactor: sh)
            let viewPos = view * SIMD4<Float>(a.coord, 1.0)
            inst.append((depth: -viewPos.z, data: data))
        }
        if inst.isEmpty { return true }
        if scene.opacity < 1.0 {
            inst.sort { $0.depth > $1.depth }
        }
        let instances = inst.map { $0.data }
        guard let buf = device.makeBuffer(bytes: instances,
                                          length: instances.count * MemoryLayout<InstanceData>.stride,
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
                                  instanceCount: instances.count)
        return true
    }

    private func atomRadius(z: Int) -> Float {
        switch scene.displayMode {
        case .spaceFill:
            return elementVdwRadius(z)
        case .wireFrame:
            return 0.06
        case .polyhedral:
            return 0
        default: // ballStick and any 2D mode
            return elementCovalentRadius(z) * scene.atomScale
        }
    }

    // MARK: - Bonds

    @discardableResult
    private func drawBonds(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let bondsDrawn: [DisplayMode] = [.ballStick, .wireFrame, .line2D, .point2D, .ballStick2D]
        guard bondsDrawn.contains(scene.displayMode) else { return true }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }
        let aoShadow = computeAOShadowFactors()

        var inst: [InstanceData] = []
        inst.reserveCapacity(scene.bonds.count)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            // Display-only clip: cull bonds where BOTH endpoints are culled.
            if b.i < frameStructureCull.count && b.j < frameStructureCull.count,
               frameStructureCull[b.i] && frameStructureCull[b.j] { continue }
            // Asymmetric-unit filter: drop bonds touching a dropped atom.
            if b.i < frameRepetitionCull.count && frameRepetitionCull[b.i] ||
               b.j < frameRepetitionCull.count && frameRepetitionCull[b.j] { continue }
            let a = atoms[b.i].coord, b2 = atoms[b.j].coord
            let dir = b2 - a
            let len = length(dir)
            guard len > 1e-5 else { continue }
            let mid = (a + b2) * 0.5
            let model = float4x4(translation: mid)
                * .rotation(fromYTo: dir / len)
                * float4x4(scale: SIMD3<Float>(scene.bondRadius, len, scene.bondRadius))
            // Coordination coloring is intentionally atom-only; bonds retain element
            // colors (with per-element overrides), or the unicolor bond color.
            let c: SIMD3<Float>
            if scene.unicolorBonds {
                c = ColorUtil.hexColor(scene.unicolorBondHex) ?? SIMD3<Float>(0.5, 0.5, 0.5)
            } else {
                c = elementColor(atoms[b.i].atomicNumber)
            }
            let aoI = b.i < aoShadow.ao.count ? aoShadow.ao[b.i] : 1.0
            let aoJ = b.j < aoShadow.ao.count ? aoShadow.ao[b.j] : 1.0
            let shI = b.i < aoShadow.shadow.count ? aoShadow.shadow[b.i] : 1.0
            let shJ = b.j < aoShadow.shadow.count ? aoShadow.shadow[b.j] : 1.0
            inst.append(InstanceData(model: model, color: SIMD4(c.x, c.y, c.z, 1.0), radius: 1.0, metalness: 0.0,
                                    aoFactor: (aoI + aoJ) * 0.5, shadowFactor: (shI + shJ) * 0.5))
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

    /// Transparent structure rendering: collects atoms and bonds, sorts them
    /// back-to-front by view depth, and draws them with depth writes disabled.
    /// This ensures correct alpha blending regardless of object type or draw
    /// order. Consecutive same-type objects are batched into instanced draws
    /// to minimize mesh switches.
    private func drawTransparentStructure(enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let transparentDepthState = transparentDepthState else { return false }
        enc.setDepthStencilState(transparentDepthState)
        defer { enc.setDepthStencilState(depthStencilState) }

        let view = sceneView(frameBuffer)
        let selected = Set(scene.selectedAtoms)
        let aoShadow = computeAOShadowFactors()

        // Build atom instances with depths.
        var atomInst: [(depth: Float, data: InstanceData)] = []
        atomInst.reserveCapacity(scene.atoms.count)
        for (i, a) in scene.atoms.enumerated() {
            if isAtomCulled(i) { continue }
            let radius = atomRadius(z: a.atomicNumber)
            if radius <= 0 { continue }
            let c = atomColor(at: i, selected: selected.contains(i))
            let ao = i < aoShadow.ao.count ? aoShadow.ao[i] : 1.0
            let sh = i < aoShadow.shadow.count ? aoShadow.shadow[i] : 1.0
            let data = InstanceData(model: float4x4(translation: a.coord),
                                    color: SIMD4(c.x, c.y, c.z, 1.0),
                                    radius: radius, metalness: 0.0,
                                    aoFactor: ao, shadowFactor: sh)
            let viewPos = view * SIMD4<Float>(a.coord, 1.0)
            atomInst.append((depth: -viewPos.z, data: data))
        }

        // Build bond instances with depths.
        var bondInst: [(depth: Float, data: InstanceData)] = []
        bondInst.reserveCapacity(scene.bonds.count)
        for b in scene.bonds {
            guard b.i >= 0, b.i < scene.atoms.count, b.j >= 0, b.j < scene.atoms.count else { continue }
            // Display-only clip: cull bonds where BOTH endpoints are culled.
            if b.i < frameStructureCull.count && b.j < frameStructureCull.count,
               frameStructureCull[b.i] && frameStructureCull[b.j] { continue }
            // Asymmetric-unit filter: drop bonds touching a dropped atom.
            if b.i < frameRepetitionCull.count && frameRepetitionCull[b.i] ||
               b.j < frameRepetitionCull.count && frameRepetitionCull[b.j] { continue }
            let a = scene.atoms[b.i].coord, b2 = scene.atoms[b.j].coord
            let dir = b2 - a
            let len = length(dir)
            guard len > 1e-5 else { continue }
            let mid = (a + b2) * 0.5
            let model = float4x4(translation: mid)
                * .rotation(fromYTo: dir / len)
                * float4x4(scale: SIMD3<Float>(scene.bondRadius, len, scene.bondRadius))
            let c: SIMD3<Float>
            if scene.unicolorBonds {
                c = ColorUtil.hexColor(scene.unicolorBondHex) ?? SIMD3<Float>(0.5, 0.5, 0.5)
            } else {
                c = elementColor(scene.atoms[b.i].atomicNumber)
            }
            let aoI = b.i < aoShadow.ao.count ? aoShadow.ao[b.i] : 1.0
            let aoJ = b.j < aoShadow.ao.count ? aoShadow.ao[b.j] : 1.0
            let shI = b.i < aoShadow.shadow.count ? aoShadow.shadow[b.i] : 1.0
            let shJ = b.j < aoShadow.shadow.count ? aoShadow.shadow[b.j] : 1.0
            let data = InstanceData(model: model, color: SIMD4(c.x, c.y, c.z, 1.0),
                                    radius: 1.0, metalness: 0.0,
                                    aoFactor: (aoI + aoJ) * 0.5, shadowFactor: (shI + shJ) * 0.5)
            let viewPos = view * SIMD4<Float>(mid, 1.0)
            bondInst.append((depth: -viewPos.z, data: data))
        }

        // Unified back-to-front list: (depth, isAtom, index).
        var objects: [(depth: Float, isAtom: Bool, index: Int)] = []
        objects.reserveCapacity(atomInst.count + bondInst.count)
        for (i, atom) in atomInst.enumerated() {
            objects.append((depth: atom.depth, isAtom: true, index: i))
        }
        for (i, bond) in bondInst.enumerated() {
            objects.append((depth: bond.depth, isAtom: false, index: i))
        }
        objects.sort { $0.depth > $1.depth }

        // Draw in sorted order, grouping consecutive same-type objects into
        // instanced batches to minimize mesh switches.
        enc.setRenderPipelineState(atomPipeline)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)

        var i = 0
        while i < objects.count {
            let isAtom = objects[i].isAtom
            var batch: [Int] = []
            while i < objects.count && objects[i].isAtom == isAtom {
                batch.append(objects[i].index)
                i += 1
            }
            guard !batch.isEmpty else { continue }
            let instances = batch.map { isAtom ? atomInst[$0].data : bondInst[$0].data }
            guard let buf = device.makeBuffer(bytes: instances,
                                              length: instances.count * MemoryLayout<InstanceData>.stride,
                                              options: []) else { return false }
            let meshVB = isAtom ? sphereVB : cylinderVB
            let meshIB = isAtom ? sphereIB : cylinderIB
            enc.setVertexBuffer(meshVB, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: meshIB.length / MemoryLayout<UInt16>.stride,
                                      indexType: .uint16,
                                      indexBuffer: meshIB,
                                      indexBufferOffset: 0,
                                      instanceCount: instances.count)
        }
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

    // MARK: - Comparison displacement arrows

    /// Runtime-only displacement arrows from a two-structure comparison,
    /// installed by the controller (never persisted). Each entry draws an arrow
    /// from `start` to `start + vector` at 1:1 scale in Å, using the shared line
    /// pipeline. Gated on the controller-set toggle so structures without a
    /// comparison draw nothing.
    @discardableResult
    private func drawDisplacementArrows(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard showDisplacementArrows, !displacementArrows.isEmpty else { return true }
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(displacementArrows.count * 8)
        let headFrac: Float = 0.18
        let headSpread: Float = 0.5
        for arrow in displacementArrows {
            let start = arrow.start
            let vector = arrow.vector
            guard start.isFinite, vector.isFinite else { continue }
            let length = simd_length(vector)
            guard length > 1e-6, length.isFinite else { continue }
            let tip = start + vector
            verts.append(start); verts.append(tip)
            let dir = vector / length
            let perp = makePerpendicular(dir)
            let side = length * headFrac
            let back = tip - dir * side
            let left = back + perp * side * headSpread
            let right = back - perp * side * headSpread
            verts.append(tip); verts.append(left)
            verts.append(tip); verts.append(right)
        }
        if verts.isEmpty { return true }
        return drawLineBuffer(verts, color: SIMD3<Float>(1.0, 0.2, 0.9), enc: enc, frameBuffer: frameBuffer)
    }

    /// Runtime-only trajectory trail: draws consecutive pairs of `trajectoryTrails`
    /// vertices as thin magenta line segments using the shared line pipeline.
    /// Gated on `showTrajectoryTrails` and non-empty vertices; non-finite
    /// vertices are skipped. Mirrors the displacement-arrow draw path.
    @discardableResult
    private func drawTrajectoryTrails(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard showTrajectoryTrails, !trajectoryTrails.isEmpty else { return true }
        var verts: [SIMD3<Float>] = []
        let count = trajectoryTrails.count
        guard count >= 2 else { return true }
        var prev = trajectoryTrails[0]
        for i in 1..<count {
            let cur = trajectoryTrails[i]
            if prev.isFinite && cur.isFinite {
                verts.append(prev); verts.append(cur)
            }
            prev = cur
        }
        if verts.isEmpty { return true }
        return drawLineBuffer(verts, color: SIMD3<Float>(1.0, 0.2, 0.9), enc: enc, frameBuffer: frameBuffer)
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
                : max(3.0, elementCovalentRadius(a.atomicNumber) * scene.atomScale * 12.0)
            let rx = rPx / (wF * 0.5)
            let ry = rPx / (hF * 0.5)
            let c = atomColor(at: i, selected: selected.contains(i))
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (-1, 1), (-1, 1), (1, -1), (1, 1)]
            for (lx, ly) in corners {
                verts.append(V(px: ndc.x + lx * rx, py: ndc.y + ly * ry, lx: lx, ly: ly, r: c.x, g: c.y, b: c.z))
            }
        }
        if verts.isEmpty { return true }
        guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else { return false }
        enc.setRenderPipelineState(flat2DPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)  // FrameData (opacity) for flat2D_f
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        return true
    }

    /// 2D bonds: screen-space line segments drawn as quads through the flat2D
    /// pipeline so they honor opacity (unlike the line pipeline which is opaque).
    /// Each segment is expanded perpendicular to its screen-space direction.
    @discardableResult
    private func drawBonds2D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard scene.displayMode == .ballStick2D || scene.displayMode == .line2D else { return true }
        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }
        let view = sceneView(frameBuffer)
        let proj = sceneProj(frameBuffer)
        let wF = Float(lastW), hF = Float(lastH)
        let bondWidth: Float = 2.0  // pixels
        let halfW = bondWidth / (wF * 0.5)
        let halfH = bondWidth / (hF * 0.5)
        let bondColor: SIMD3<Float> = scene.unicolorBonds
            ? (ColorUtil.hexColor(scene.unicolorBondHex) ?? SIMD3<Float>(0.5, 0.5, 0.5))
            : SIMD3<Float>(0.35, 0.35, 0.35)

        struct V { var px: Float; var py: Float; var lx: Float; var ly: Float; var r: Float; var g: Float; var b: Float }
        var verts: [V] = []
        verts.reserveCapacity(scene.bonds.count * 6)
        for b in scene.bonds {
            guard b.i >= 0, b.i < atoms.count, b.j >= 0, b.j < atoms.count else { continue }
            guard let ndc0 = projectNDC2D(atoms[b.i].coord, view: view, proj: proj),
                  let ndc1 = projectNDC2D(atoms[b.j].coord, view: view, proj: proj) else { continue }
            let dir = SIMD2<Float>(ndc1.x - ndc0.x, ndc1.y - ndc0.y)
            let dirLen = simd_length(dir)
            guard dirLen > 1e-6 else { continue }
            let perp = SIMD2<Float>(-dir.y, dir.x) / dirLen
            let o = SIMD2<Float>(perp.x * halfW, perp.y * halfH)
            let v00 = SIMD2<Float>(ndc0.x + o.x, ndc0.y + o.y)
            let v01 = SIMD2<Float>(ndc0.x - o.x, ndc0.y - o.y)
            let v10 = SIMD2<Float>(ndc1.x + o.x, ndc1.y + o.y)
            let v11 = SIMD2<Float>(ndc1.x - o.x, ndc1.y - o.y)
            // Two triangles: (v00, v01, v10) and (v01, v11, v10)
            for (px, py) in [(v00.x, v00.y), (v01.x, v01.y), (v10.x, v10.y), (v01.x, v01.y), (v11.x, v11.y), (v10.x, v10.y)] {
                verts.append(V(px: px, py: py, lx: 0, ly: 0, r: bondColor.x, g: bondColor.y, b: bondColor.z))
            }
        }
        if verts.isEmpty { return true }
        guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else { return false }
        enc.setRenderPipelineState(flat2DPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)  // FrameData (opacity) for flat2D_f
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        return true
    }

    /// Project a world point to NDC for 2D rendering, returning nil if the point
    /// is behind the camera or produces non-finite coordinates.
    private func projectNDC2D(_ world: SIMD3<Float>, view: float4x4, proj: float4x4) -> SIMD2<Float>? {
        let clip = proj * view * SIMD4<Float>(world, 1)
        guard clip.w > 1e-6 else { return nil }
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        guard ndc.x.isFinite && ndc.y.isFinite else { return nil }
        return ndc
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
        let key = (atoms: atoms, bonds: scene.bonds, selected: scene.selectedAtoms,
                   coordinationNumbers: coordinationNumbers,
                   showCoordinationColors: showCoordinationColors,
                   atomColorScheme: scene.atomColorScheme,
                   atomScale: scene.atomScale,
                   elementOverridesFP: elementOverridesFingerprint())
        if let pk = cachedPolyKey,
           pk.selected == key.selected,
           pk.coordinationNumbers == key.coordinationNumbers,
           pk.showCoordinationColors == key.showCoordinationColors,
           pk.atomColorScheme == key.atomColorScheme,
           pk.atomScale == key.atomScale,
           pk.elementOverridesFP == key.elementOverridesFP,
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
            // Display-only clip + asymmetric-unit filter.
            if isAtomCulled(i) { continue }
            guard neigh[i].count >= 3 else { continue }
            guard let tris = Geometry.polyhedronFaces(center: a.coord, neighbors: neigh[i], maxNeighbors: 12) else { continue }
            let col = atomColor(at: i, selected: selected.contains(i))
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

    /// Transparent polyhedral rendering: builds ALL triangles from ALL cells,
    /// sorts them back-to-front by centroid depth, and draws with depth writes
    /// disabled so alpha blending composites correctly. Triangle-level sorting
    /// is deterministic and defensible for convex cells. All sorted triangles
    /// are packed into a single contiguous vertex buffer with one draw call.
    private func drawPolyhedralTransparent(enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard let transparentDepthState = transparentDepthState else { return false }
        enc.setDepthStencilState(transparentDepthState)
        defer { enc.setDepthStencilState(depthStencilState) }

        let atoms = scene.atoms
        guard atoms.count > 1 else { return true }
        let neigh = buildNeighborCoords()
        let selected = Set(scene.selectedAtoms)
        let key = (atoms: atoms, bonds: scene.bonds, selected: scene.selectedAtoms,
                   coordinationNumbers: coordinationNumbers,
                   showCoordinationColors: showCoordinationColors,
                   atomColorScheme: scene.atomColorScheme,
                   atomScale: scene.atomScale,
                   elementOverridesFP: elementOverridesFingerprint())
        // Rebuild the static triangle geometry only when the structural key changes.
        // Per frame we only apply the structure cull and re-sort by view depth.
        if !transparentPolyKeyMatches(key) {
            var atomTris: [[TransparentTri]] = []
            atomTris.reserveCapacity(atoms.count)
            for (i, a) in atoms.enumerated() {
                guard neigh[i].count >= 3 else { atomTris.append([]); continue }
                guard let tris = Geometry.polyhedronFaces(center: a.coord, neighbors: neigh[i], maxNeighbors: 12) else {
                    atomTris.append([]); continue
                }
                let col = atomColor(at: i, selected: selected.contains(i))
                var out: [TransparentTri] = []
                out.reserveCapacity(tris.count / 3)
                var j = 0
                while j < tris.count {
                    let p0 = tris[j], p1 = tris[j + 1], p2 = tris[j + 2]
                    let n = normalize(cross(p1 - p0, p2 - p0))
                    let centroid = (p0 + p1 + p2) / 3.0
                    out.append(TransparentTri(
                        v0: PolyVert(x: p0.x, y: p0.y, z: p0.z, nx: n.x, ny: n.y, nz: n.z, r: col.x, g: col.y, b: col.z),
                        v1: PolyVert(x: p1.x, y: p1.y, z: p1.z, nx: n.x, ny: n.y, nz: n.z, r: col.x, g: col.y, b: col.z),
                        v2: PolyVert(x: p2.x, y: p2.y, z: p2.z, nx: n.x, ny: n.y, nz: n.z, r: col.x, g: col.y, b: col.z),
                        centroid: centroid))
                    j += 3
                }
                atomTris.append(out)
            }
            cachedTransparentPoly = TransparentPolyCache(
                atoms: key.atoms, bonds: key.bonds, selected: key.selected,
                coordinationNumbers: key.coordinationNumbers,
                showCoordinationColors: key.showCoordinationColors,
                atomColorScheme: key.atomColorScheme,
                atomScale: key.atomScale,
                elementOverridesFP: key.elementOverridesFP, atomTris: atomTris)
        }
        guard let cache = cachedTransparentPoly else { return true }

        let view = sceneView(frameBuffer)
        // Per-frame: collect the visible (non-culled) triangles with their view-space
        // centroid depths for back-to-front sorting. Geometry is cached; only this
        // depth sort + repack is recomputed each frame.
        var triData: [(depth: Float, tri: TransparentTri)] = []
        for (i, tris) in cache.atomTris.enumerated() {
            if isAtomCulled(i) { continue }
            for tri in tris {
                let viewPos = view * SIMD4<Float>(tri.centroid, 1.0)
                triData.append((depth: -viewPos.z, tri: tri))
            }
        }
        if triData.isEmpty { return true }
        // Sort back-to-front (largest depth first).
        triData.sort { $0.depth > $1.depth }
        // Pack all sorted triangles into one contiguous vertex buffer.
        var allVerts: [PolyVert] = []
        allVerts.reserveCapacity(triData.count * 3)
        for tri in triData {
            allVerts.append(tri.tri.v0)
            allVerts.append(tri.tri.v1)
            allVerts.append(tri.tri.v2)
        }
        guard let buf = device.makeBuffer(bytes: allVerts,
                                          length: allVerts.count * MemoryLayout<PolyVert>.stride,
                                          options: []) else { return false }
        enc.setRenderPipelineState(polyPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: allVerts.count)
        return true
    }

    /// Structural-key equality for the transparent polyhedral cache, mirroring the
    /// opaque `drawPolyhedral` cache's comparison (Bond is not Equatable, so bonds
    /// are compared field-wise).
    private func transparentPolyKeyMatches(_ key: (atoms: [Atom], bonds: [Bond], selected: [Int],
                                            coordinationNumbers: [Int], showCoordinationColors: Bool,
                                            atomColorScheme: AtomColorScheme, atomScale: Float,
                                            elementOverridesFP: UInt64)) -> Bool {
        guard let pk = cachedTransparentPoly else { return false }
        return pk.selected == key.selected
            && pk.coordinationNumbers == key.coordinationNumbers
            && pk.showCoordinationColors == key.showCoordinationColors
            && pk.atomColorScheme == key.atomColorScheme
            && pk.atomScale == key.atomScale
            && pk.elementOverridesFP == key.elementOverridesFP
            && pk.atoms.count == key.atoms.count && zip(pk.atoms, key.atoms).allSatisfy { $0.coord == $1.coord && $0.atomicNumber == $1.atomicNumber }
            && pk.bonds.count == key.bonds.count && zip(pk.bonds, key.bonds).allSatisfy { $0.i == $1.i && $0.j == $1.j }
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
            var edgePairs: [(SIMD3<Float>, SIMD3<Float>)] = []
            edgePairs.reserveCapacity(replicas * 12)
            for i in 0..<sc.n1 {
                for j in 0..<sc.n2 {
                    for k in 0..<sc.n3 {
                        let t = a * Float(i) + b * Float(j) + c * Float(k)
                        let o = base + t
                        let corners = [o, a + o, a + b + o, b + o, c + o, a + c + o, b + c + o, a + b + c + o]
                        for (ci, cj) in edges { edgePairs.append((corners[ci], corners[cj])) }
                    }
                }
            }
            if scene.cellRodsEnabled {
                return drawCellRods(enc, frameBuffer: frameBuffer, edgePairs: edgePairs)
            }
            var frameVerts: [SIMD3<Float>] = []
            frameVerts.reserveCapacity(edgePairs.count * 2)
            for (p, q) in edgePairs { frameVerts.append(p); frameVerts.append(q) }
            return drawLineBuffer(frameVerts, color: SIMD3<Float>(0.75, 0.75, 0.75), enc: enc, frameBuffer: frameBuffer)
        }
        return true
    }

    /// Draw the cell frame edges as lit rods (XCrySDen "Crystal Cells As Rods")
    /// using the shared cylinder mesh + atom pipeline. Radius derives from the
    /// hydrogen covalent radius scaled by `scene.cellRodFactor`.
    private func drawCellRods(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?,
                              edgePairs: [(SIMD3<Float>, SIMD3<Float>)]) -> Bool {
        let radius = scene.cellRodFactor * elementCovalentRadius(1)
        if radius <= 0 { return true }
        let color = SIMD3<Float>(0.75, 0.75, 0.75)
        var inst: [InstanceData] = []
        inst.reserveCapacity(edgePairs.count)
        for (p, q) in edgePairs {
            let dir = q - p
            let len = length(dir)
            guard len > 1e-5 else { continue }
            let mid = (p + q) * 0.5
            let model = float4x4(translation: mid)
                * .rotation(fromYTo: dir / len)
                * float4x4(scale: SIMD3<Float>(radius, len, radius))
            inst.append(InstanceData(model: model, color: SIMD4(color, 1.0), radius: 1.0,
                                     metalness: 0.0, aoFactor: 1.0, shadowFactor: 1.0))
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

    /// Draw detected H-bonds (`scene.hbondPairs`) as thin dashed line segments
    /// between each hydrogen and its acceptor, tinted with
    /// `hbondSettings.colorHex`. Reuses the existing line primitive with a
    /// reduced width; deterministic (sorted) output.
    @discardableResult
    private func drawHbonds(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard scene.hbondSettings.enabled, !scene.hbondPairs.isEmpty else { return true }
        let atoms = scene.atoms
        let pairs = scene.hbondPairs.sorted {
            ($0.donor, $0.hydrogen, $0.acceptor) < ($1.donor, $1.hydrogen, $1.acceptor)
        }
        let color = ColorUtil.hexColor(scene.hbondSettings.colorHex) ?? SIMD3<Float>(0.53, 0.8, 1.0)
        // Dashed look: emit short sub-segments with gaps along each H-bond.
        let dashes = 8
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(pairs.count * dashes * 2)
        for p in pairs {
            guard p.donor >= 0, p.donor < atoms.count,
                  p.hydrogen >= 0, p.hydrogen < atoms.count,
                  p.acceptor >= 0, p.acceptor < atoms.count else { continue }
            // Cull a dashed segment if any of its three atoms is culled (structure
            // clip or asymmetric-unit filter), matching the bond/atom draw paths.
            if isAtomCulled(p.donor) || isAtomCulled(p.hydrogen) || isAtomCulled(p.acceptor) { continue }
            let h = atoms[p.hydrogen].coord
            // For crystals the bond reaches the periodic image that satisfied the
            // H…A criteria; for molecules the home copy is used.
            let a = p.acceptorImage ?? atoms[p.acceptor].coord
            for s in 0..<dashes where s % 2 == 0 {
                let t0 = Float(s) / Float(dashes)
                let t1 = Float(s + 1) / Float(dashes)
                verts.append(h + (a - h) * t0)
                verts.append(h + (a - h) * t1)
            }
        }
        guard !verts.isEmpty else { return true }
        return drawLineBuffer(verts, color: color, enc: enc, frameBuffer: frameBuffer)
    }

    /// Draw the molecular (solvent-accessible) surface as a translucent,
    /// depth-tested triangle mesh tinted with `molecularSurfaceSettings.colorHex`
    /// at the configured opacity. Uses the poly (flat-shaded, lit) pipeline with
    /// transparent blending. Skipped when the surface generator returns nil.
    @discardableResult
    private func drawMolecularSurface(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let settings = scene.molecularSurfaceSettings
        guard settings.enabled else {
            // Release the cached GPU buffers when the surface is toggled off so
            // they don't linger until the next (optional) rebuild.
            if cachedMolSurface != nil { cachedMolSurface = nil }
            return true
        }
        let fp = atomFingerprint()
        let overridesFP = elementOverridesFingerprint()
        let color = ColorUtil.hexColor(settings.colorHex) ?? SIMD3<Float>(0.69, 0.74, 0.77)
        if cachedMolSurface == nil ||
            cachedMolSurface!.atomFP != fp ||
            cachedMolSurface!.elementOverridesFP != overridesFP ||
            cachedMolSurface!.probeRadius != settings.probeRadius ||
            cachedMolSurface!.color != color ||
            cachedMolSurface!.opacity != settings.opacity {
            // Pass overrides through so the builder uses overridden vdW radii
            // (falls back to CPK radii when the dictionary is empty).
            guard let mesh = MolecularSurface.mesh(atoms: scene.atoms,
                                                    probeRadius: settings.probeRadius,
                                                    overrides: scene.elementOverrides) else {
                cachedMolSurface = nil
                return true
            }
            // Mesh vertices carry only position + normal; expand indices into a
            // flat lit-vertex stream with per-vertex surface color.
            let vertStride = MemoryLayout<Float>.stride * 9
            guard let vb = device.makeBuffer(length: mesh.positions.count * vertStride, options: []),
                  let ib = device.makeBuffer(bytes: mesh.indices,
                                            length: mesh.indices.count * MemoryLayout<UInt16>.stride,
                                            options: []) else {
                cachedMolSurface = nil
                return true
            }
            let p = vb.contents().assumingMemoryBound(to: Float.self)
            for i in 0..<mesh.positions.count {
                let pos = mesh.positions[i], nrm = mesh.normals[i]
                let o = i * 9
                p[o+0]=pos.x; p[o+1]=pos.y; p[o+2]=pos.z
                p[o+3]=nrm.x; p[o+4]=nrm.y; p[o+5]=nrm.z
                p[o+6]=color.x; p[o+7]=color.y; p[o+8]=color.z
            }
            cachedMolSurface = MolSurfaceCache(atomFP: fp, elementOverridesFP: overridesFP,
                                               probeRadius: settings.probeRadius,
                                               color: color, opacity: settings.opacity,
                                               vertexBuffer: vb, indexBuffer: ib,
                                               indexCount: mesh.indices.count)
        }
        guard let cache = cachedMolSurface, let frameBuffer else { return true }
        // Override the shared frame's opacity for this translucent draw.
        let ptr = frameBuffer.contents().assumingMemoryBound(to: FrameData.self)
        let base = ptr.pointee
        var tframe = base
        tframe.opacity = settings.opacity
        guard let tbuf = device.makeBuffer(bytes: &tframe, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        enc.setDepthStencilState(transparentDepthState)
        enc.setRenderPipelineState(polyPipeline)
        enc.setVertexBuffer(cache.vertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(tbuf, offset: 0, index: 2)
        enc.setFragmentBuffer(tbuf, offset: 0, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: cache.indexCount,
                                  indexType: .uint16, indexBuffer: cache.indexBuffer,
                                  indexBufferOffset: 0)
        enc.setDepthStencilState(depthStencilState)
        return true
    }

    /// Draw measurement lines between selected atoms in 3D space.
    @discardableResult
    private func drawMeasurements(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        let verts = measurementLineVertices()
        // All pairs invalid: nothing to draw, but still a successful no-op.
        guard !verts.isEmpty else { return true }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(lastW), height: Double(lastH),
                                    znear: 0, zfar: 1))
        enc.setDepthStencilState(overlayDepthState)
        return drawLineBuffer(verts, color: SIMD3<Float>(0.2, 0.6, 1), enc: enc, frameBuffer: frameBuffer)
    }

    /// Returns the world-space line vertices used for measurement overlays.
    /// Distance measurements use the same minimum-image displacement as the
    /// measurement readout; all other measurements retain their direct polyline.
    static func measurementLineVertices(for scene: Scene) -> [SIMD3<Float>] {
        guard scene.measurementMode != .none else { return [] }
        let selected = scene.selectedAtoms
        guard selected.count >= 2 else { return [] }
        let atoms = scene.atoms

        if scene.measurementMode == .distance {
            return lockedDistanceLineVertices(for: scene) ?? []
        }

        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(selected.count * 2)
        for i in 0..<(selected.count - 1) {
            let a = selected[i], b = selected[i + 1]
            // Skip a single bad pair rather than dropping valid segments collected
            // so far; guard stale negative and out-of-range indices as well.
            guard a >= 0, b >= 0, a < atoms.count, b < atoms.count else { continue }
            let from = atoms[a].coord, to = atoms[b].coord
            guard from.isFinite, to.isFinite else { continue }
            verts.append(from)
            verts.append(to)
        }
        return verts
    }

    /// Resolve a distance line only from the locked result that belongs to the
    /// current ordered selection. A missing or stale result is not permission to
    /// run the periodic solver again: the readout and overlay must agree.
    private static func lockedDistanceLineVertices(for scene: Scene) -> [SIMD3<Float>]? {
        let selected = scene.selectedAtoms
        guard scene.measurementMode == .distance,
              selected.count == 2,
              let result = scene.measurementResult,
              result.mode == .distance,
              result.atomIndices == selected,
              result.value.isFinite else { return nil }

        let atoms = scene.atoms
        let sourceIndex = selected[0], targetIndex = selected[1]
        guard sourceIndex >= 0, sourceIndex < atoms.count,
              targetIndex >= 0, targetIndex < atoms.count else { return nil }
        let source = atoms[sourceIndex].coord
        let target = atoms[targetIndex].coord
        guard source.isFinite, target.isFinite,
              let displacement = PeriodicGeometry.minimumImageDisplacement(
                  from: source, to: target, cell: scene.cell, periodicDim: scene.periodicDim
              ) else { return nil }
        let endpoint = source + displacement
        guard endpoint.isFinite else { return nil }
        return [source, endpoint]
    }

    /// Camera redraws do not change measurement geometry. Keep just one resolved
    /// distance entry; the key is deliberately limited to the two selected atoms
    /// and measurement inputs rather than the full atom array.
    private func measurementLineVertices() -> [SIMD3<Float>] {
        guard scene.measurementMode == .distance else {
            return Renderer.measurementLineVertices(for: scene)
        }
        guard let key = Renderer.distanceLineCacheKey(for: scene) else { return [] }
        if cachedDistanceLineKey == key {
            return cachedDistanceLineVertices ?? []
        }

        distanceLineResolveCount += 1
        let resolved = Renderer.lockedDistanceLineVertices(for: scene)
        cachedDistanceLineKey = key
        cachedDistanceLineVertices = resolved
        return resolved ?? []
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
        // Apply the multi-light rig to the gizmo arrows exactly as the main scene
        // does. The gizmo uses an identity view, so its light direction stays in
        // camera space — keeping the light camera-relative (AGENTS invariant).
        if let light = multiLightDir(view: matrix_identity_float4x4) {
            arrowFrame.lightDir = light.dir
            arrowFrame.diffuse = min(scene.lighting.diffuse * light.intensity, 1.0)
        }
        guard let arrowFB = device.makeBuffer(bytes: &arrowFrame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        var labelFrame = Renderer.makeFrame(view: worldToView, proj: proj,
                                            lighting: scene.lighting,
                                            eye: SIMD3<Float>(0, 0, 100))
        guard let labelFB = device.makeBuffer(bytes: &labelFrame, length: MemoryLayout<FrameData>.stride, options: []) else { return false }
        enc.setRenderPipelineState(atomPipeline)
        enc.setDepthStencilState(overlayDepthState)

        let shaftLen: Float = 0.62, shaftR: Float = 0.05
        let headLen: Float = 0.22, headR: Float = 0.13
        struct Axis { let worldAxis: SIMD3<Float>; let dir: SIMD3<Float>; let color: SIMD3<Float> }
        let axes = [
            Axis(worldAxis: SIMD3<Float>(1, 0, 0), dir: (worldToView * SIMD4<Float>(1, 0, 0, 0)).xyz, color: SIMD3<Float>(1, 0.2, 0.2)),
            Axis(worldAxis: SIMD3<Float>(0, 1, 0), dir: (worldToView * SIMD4<Float>(0, 1, 0, 0)).xyz, color: SIMD3<Float>(0.2, 1, 0.2)),
            Axis(worldAxis: SIMD3<Float>(0, 0, 1), dir: (worldToView * SIMD4<Float>(0, 0, 1, 0)).xyz, color: SIMD3<Float>(0.2, 0.2, 1)),
        ]
        func shaftModel(_ a: Axis) -> float4x4 {
            float4x4(translation: a.dir * shaftLen * 0.5) * Renderer.gizmoArrowRotation(worldToView: worldToView, worldAxis: a.worldAxis) *
            float4x4(scale: SIMD3<Float>(shaftR, shaftLen, shaftR))
        }
        func headModel(_ a: Axis) -> float4x4 {
            float4x4(translation: a.dir * shaftLen) * Renderer.gizmoArrowRotation(worldToView: worldToView, worldAxis: a.worldAxis) *
            float4x4(scale: SIMD3<Float>(headR, headLen, headR))
        }

        func drawInstances(_ meshVB: MTLBuffer, _ meshIB: MTLBuffer,
                           _ model: (Axis) -> float4x4) -> Bool {
            var inst: [InstanceData] = []
            for a in axes {
                inst.append(InstanceData(model: model(a), color: SIMD4(a.color, 1),
                                         radius: 1.0, metalness: 0.0,
                                         aoFactor: 1.0, shadowFactor: 1.0))
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

    /// Generate line segments for a star-shaped marker: a 3-axis cross plus
    /// diagonal "sparkle" lines in every octant. More visually prominent than
    /// a plain cross, so high-symmetry k-path nodes read clearly against the
    /// BZ faces and structure. The sparkle lines use a shorter half-length so
    /// the central cross still dominates. Returns [] for a non-finite center.
    static func starMarkerSegments(_ world: SIMD3<Float>, half: Float) -> [SIMD3<Float>] {
        guard world.x.isFinite && world.y.isFinite && world.z.isFinite else { return [] }
        guard half.isFinite, half > 0 else { return [] }
        // Primary cross axes.
        let ax = SIMD3<Float>(half, 0, 0), ay = SIMD3<Float>(0, half, 0), az = SIMD3<Float>(0, 0, half)
        var segs = [world - ax, world + ax, world - ay, world + ay, world - az, world + az]
        // Diagonal sparkle lines (shortened to 45% of the primary half-length)
        // in the XY, XZ, and YZ planes — 3 extra line segments total.
        let s = half * 0.45
        let dxy = SIMD3<Float>(s, s, 0), dxz = SIMD3<Float>(s, 0, s), dyz = SIMD3<Float>(0, s, s)
        segs.append(contentsOf: [
            world - dxy, world + dxy,   // XY-plane diagonals
            world - dxz, world + dxz,   // XZ-plane diagonals
            world - dyz, world + dyz,   // YZ-plane diagonals
        ])
        return segs
    }

    /// Expand world-space line segments into NDC-space quads for configurable
    /// line width. Each segment (p0,p1) becomes 4 vertices (2 triangles) expanded
    /// perpendicular to the line direction in NDC by half the pixel width.
    private func expandLineSegmentsToQuads(_ verts: [SIMD3<Float>], view: float4x4, proj: float4x4,
                                            viewportW: Int, viewportH: Int,
                                            pixelWidth: Float) -> [SIMD3<Float>]? {
        guard verts.count >= 2, verts.count % 2 == 0 else { return nil }
        let wF = Float(viewportW)
        let hF = Float(viewportH)
        guard wF > 0, hF > 0 else { return nil }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(verts.count * 3)
        var i = 0
        while i < verts.count {
            let p0 = verts[i], p1 = verts[i + 1]
            let view0 = view * SIMD4<Float>(p0, 1)
            let view1 = view * SIMD4<Float>(p1, 1)
            let clip0 = proj * view0
            let clip1 = proj * view1
            guard clip0.w > 1e-6, clip1.w > 1e-6 else { i += 2; continue }
            let ndc0 = clip0.xyz / clip0.w
            let ndc1 = clip1.xyz / clip1.w
            // Compute perpendicular in pixel space, then convert back to NDC.
            // This gives correct aspect ratio: x NDC units = wF/2 pixels,
            // y NDC units = hF/2 pixels.
            let dxNDCPerPixel = 2.0 / wF
            let dyNDCPerPixel = 2.0 / hF
            let dirPixels = SIMD2<Float>((ndc1.x - ndc0.x) / dxNDCPerPixel,
                                        (ndc1.y - ndc0.y) / dyNDCPerPixel)
            let dirLenPixels = simd_length(dirPixels)
            guard dirLenPixels > 1e-6 else { i += 2; continue }
            let perpPixels = SIMD2<Float>(-dirPixels.y, dirPixels.x) / dirLenPixels
            // Half-width in NDC units (per-axis scaling for correct aspect).
            let ox = perpPixels.x * (pixelWidth * 0.5) * dxNDCPerPixel
            let oy = perpPixels.y * (pixelWidth * 0.5) * dyNDCPerPixel
            // Preserve each endpoint's NDC z (not an average).
            let v00 = SIMD3<Float>(ndc0.x + ox, ndc0.y + oy, ndc0.z)
            let v01 = SIMD3<Float>(ndc0.x - ox, ndc0.y - oy, ndc0.z)
            let v10 = SIMD3<Float>(ndc1.x + ox, ndc1.y + oy, ndc1.z)
            let v11 = SIMD3<Float>(ndc1.x - ox, ndc1.y - oy, ndc1.z)
            result.append(contentsOf: [v00, v01, v10, v01, v11, v10])
            i += 2
        }
        return result.isEmpty ? nil : result
    }

    /// Compute the model rotation for a gizmo arrow. The gizmo renders in
    /// camera space (view = identity), with arrows pointing along the
    /// camera-space direction of a world axis.
    ///
    /// A naive `rotation(fromYTo: dir)` rotates the cylinder's +Y to `dir`, but
    /// the resulting surface normals `rot(Y->dir) * n_local` do NOT match the
    /// main scene's normals `worldToView * rot(Y->worldAxis) * n_local` in
    /// general -- rotation composition does not commute with `worldToView`.
    /// The mismatch makes the gizmo's diffuse shading disagree with the
    /// structure's: the dark side appears to rotate with the arrow instead of
    /// staying viewer-fixed.
    ///
    /// Pre-composing with `worldToView` fixes this while the arrow still points
    /// along `dir = worldToView * worldAxis`: the normals become
    /// `worldToView * rot(Y->worldAxis) * n_local`, whose dot product with the
    /// camera-space light `viewLight` equals the main scene's
    /// `dot(rot(Y->worldAxis)*n_local, worldToView^T * viewLight)`. The gizmo
    /// then shares the main scene's lighting basis.
    ///
    /// `worldAxis` is passed directly rather than recovered by inverting
    /// `worldToView * worldAxis = dir`; it is already known (a coordinate
    /// axis), so no inversion/reconstruction is needed.
    static func gizmoArrowRotation(worldToView: float4x4, worldAxis: SIMD3<Float>) -> float4x4 {
        return worldToView * .rotation(fromYTo: worldAxis)
    }

    /// Draw a line buffer with an optional explicit line width. When `lineWidth`
    /// is nil, the scene's global `lineWidth` is used. Callers that need a
    /// specific width (e.g. the BZ k-path) pass an explicit value.
    private func drawLineBuffer(_ verts: [SIMD3<Float>], color: SIMD3<Float>,
                                enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?,
                                lineWidth: Float? = nil) -> Bool {
        let width = lineWidth ?? scene.lineWidth
        if width <= 1.0 {
            guard let lineVB = device.makeBuffer(bytes: verts,
                                                 length: verts.count * MemoryLayout<SIMD3<Float>>.stride,
                                                 options: []) else { return false }
            var c = color
            guard let colorBuf = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: []) else { return false }
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBuffer(lineVB, offset: 0, index: 0)
            enc.setVertexBuffer(colorBuf, offset: 0, index: 3)
            enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)  // FrameData (opacity) for lf_main
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
        } else {
            let view = sceneView(frameBuffer)
            let proj = sceneProj(frameBuffer)
            guard let quads = expandLineSegmentsToQuads(verts, view: view, proj: proj,
                                                         viewportW: lastW, viewportH: lastH,
                                                         pixelWidth: width) else { return true }
            guard let lineVB = device.makeBuffer(bytes: quads,
                                                 length: quads.count * MemoryLayout<SIMD3<Float>>.stride,
                                                 options: []) else { return false }
            var c = color
            guard let colorBuf = device.makeBuffer(bytes: &c, length: MemoryLayout<SIMD3<Float>>.stride, options: []) else { return false }
            enc.setRenderPipelineState(thickLinePipeline)
            enc.setVertexBuffer(lineVB, offset: 0, index: 0)
            enc.setVertexBuffer(colorBuf, offset: 0, index: 3)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)  // FrameData (opacity) for thickLine_f
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quads.count)
        }
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
        // Landmark geometry is shared with controller-side picking and AX framing.
        let displayedHalfExtent = pres.displayedHalfExtent
        guard displayedHalfExtent.isFinite, displayedHalfExtent > 1e-5 else { return true }
        let bzColor = SIMD3<Float>(0.85, 0.30, 0.95)
        let landmarkHalf = pres.landmarkHalfExtent                 // white BZ landmark crosses
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
        // Edit landmarks are actionable picking targets, so they must not vanish
        // behind the structure. Scope the always-pass state to these crosses only;
        // the face wireframe remains normally depth-tested and route rendering
        // below restores its own less-equal/no-write semantics.
        let landmarkOK: Bool
        if landmarkSegs.isEmpty {
            landmarkOK = true
        } else {
            enc.setDepthStencilState(overlayDepthState)
            landmarkOK = drawLineBuffer(landmarkSegs, color: SIMD3(1, 1, 1), enc: enc, frameBuffer: frameBuffer)
            if let depthStencilState { enc.setDepthStencilState(depthStencilState) }
        }

        // k-path route overlay: amber segments between consecutive valid nodes, and a
        // larger cyan 3-axis cross at every valid node. Drawn on top of the landmarks
        // with a `.lessEqual`/no-write depth state so equal-depth route fragments are
        // not dropped behind the white landmarks drawn a moment earlier. The normal
        // state was restored after the landmark overlay, so route fragments still
        // respect structure/BZ depth.
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
        // Thicker line width for the k-path route segments so the path reads
        // clearly against the BZ faces and structure. MSAA (applied during the
        // render pass) anti-aliases the edges.
        let routeLineWidth: Float = 3.0
        let amber = SIMD3<Float>(1.0, 0.55, 0.1)
        let segOK = segVerts.isEmpty ? true : drawLineBuffer(segVerts, color: amber, enc: enc, frameBuffer: frameBuffer, lineWidth: routeLineWidth)

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
                // Highlighted (sidebar-selected) node: larger star marker in a
                // vivid green so it reads against the cyan nodes, amber segments,
                // and purple BZ faces.
                highlightVerts.append(contentsOf: Renderer.starMarkerSegments(mapped[i], half: routeNodeHalf * 1.6))
            } else {
                // Standard node: a star marker (cross + diagonals) for a more
                // prominent, beautiful readout than a plain 3-axis cross.
                nodeVerts.append(contentsOf: Renderer.starMarkerSegments(mapped[i], half: routeNodeHalf))
            }
        }
        let cyan = SIMD3<Float>(0.2, 0.8, 1.0)
        let nodeOK = nodeVerts.isEmpty ? true : drawLineBuffer(nodeVerts, color: cyan, enc: enc, frameBuffer: frameBuffer, lineWidth: routeLineWidth)
        let highlight = SIMD3<Float>(0.2, 1.0, 0.3)
        let highlightOK = highlightVerts.isEmpty ? true : drawLineBuffer(highlightVerts, color: highlight, enc: enc, frameBuffer: frameBuffer, lineWidth: routeLineWidth)
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
        let shells = currentIsoShells()
        let clip = isoClipPlane()
        // When the spec list or clip plane changed since the last rebuild, drop the
        // dynamic caches so every shell rebuilds against the new inputs.
        let specsChanged = cachedIsoSpecSignature != scene.isoSurfaces
        let clipChanged = cachedIsoClip != scene.clipPlane
        if specsChanged || clipChanged {
            cachedIsoBuffers = []
            cachedIsoKeys = []
            cachedIsoTriangleCounts = []
            cachedIsoSpecSignature = scene.isoSurfaces
            cachedIsoClip = scene.clipPlane
        }
        // Keep the dynamic caches sized to the shell count.
        if cachedIsoBuffers.count != shells.count {
            cachedIsoBuffers = [MTLBuffer?](repeating: nil, count: shells.count)
            cachedIsoKeys = [IsoCacheKey?](repeating: nil, count: shells.count)
            cachedIsoTriangleCounts = [Int](repeating: 0, count: shells.count)
        }
        let clipEnabled = clip != nil
        let clipH = scene.clipPlane?.h ?? 0
        let clipK = scene.clipPlane?.k ?? 0
        let clipL = scene.clipPlane?.l ?? 0
        let clipDist = scene.clipPlane?.distance ?? 0
        for (idx, shell) in shells.enumerated() {
            // Legacy shells use scene.isoLevel; spec shells use each spec's own
            // level. The IsoMesh is surfaced at sign*level exactly like the shells.
            let level: Float
            if scene.isoSurfaces.isEmpty {
                level = scene.isoLevel
            } else {
                // `idx` indexes the FILTERED enabled-specs list; map back to the
                // original isoSurfaces to read the spec's level.
                let enabledSpecs = scene.isoSurfaces.filter { $0.enabled }
                level = enabledSpecs[idx].level
            }
            let key = IsoCacheKey(nx: field.nx, ny: field.ny, nz: field.nz,
                                  origin: field.origin,
                                  vec0: field.vec[0], vec1: field.vec[1], vec2: field.vec[2],
                                  isoLevel: shell.sign * level, sign: shell.sign,
                                  generation: scalarFieldGeneration,
                                  clipEnabled: clipEnabled, clipH: clipH, clipK: clipK,
                                  clipL: clipL, clipDistance: clipDist,
                                  colorBits: (UInt32((shell.color.x * 255).rounded()) << 16)
                                            | (UInt32((shell.color.y * 255).rounded()) << 8)
                                            | UInt32((shell.color.z * 255).rounded()))
            if cachedIsoKeys[idx] != key {
                isoRebuildCount += 1
                let mesh = IsoMesh(field: field, isoLevel: shell.sign * level, sign: shell.sign, color: shell.color)
                // A truncated shell (triangle cap hit or Int-overflowed grid) is a
                // partial surface — never cache or render it as a complete one. Surface
                // the failure so the frame drops rather than silently drawing a
                // truncated shell. A valid empty surface (no crossing) has overflow==false
                // and falls through to the triangleCount==0 branch below.
                if mesh.overflow {
                    return false
                }
                // Apply the clipping plane to the shell mesh when active.
                let clipped: FieldSlice.ClippedMesh
                if let clip {
                    clipped = FieldSlice.clipTrianglesWithOverflow(mesh.vertices, plane: clip, keepSide: 1)
                } else {
                    clipped = FieldSlice.ClippedMesh(vertices: mesh.vertices, overflow: false)
                }
                // A clipped shell that overflowed the 5M-triangle cap is a truncated surface
                // — never cache or render it as complete. Surface the failure so the frame
                // drops rather than silently drawing a truncated shell, mirroring the
                // IsoMesh.overflow check above.
                if clipped.overflow {
                    return false
                }
                let verts = clipped.vertices
                if !verts.isEmpty {
                    // A non-empty mesh that fails to allocate is a real failure — do not
                    // cache nil as "empty", or the frame would silently drop the surface
                    // and never retry. Surface the failure instead.
                    guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.stride, options: []) else {
                        return false
                    }
                    cachedIsoBuffers[idx] = buf
                    cachedIsoTriangleCounts[idx] = verts.count / 27
                } else {
                    cachedIsoBuffers[idx] = nil
                    cachedIsoTriangleCounts[idx] = 0
                }
                cachedIsoKeys[idx] = key
            }
            guard let buf = cachedIsoBuffers[idx], cachedIsoTriangleCounts[idx] > 0 else { continue }
            enc.setRenderPipelineState(polyPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)   // FrameData (lighting)
            enc.setFragmentBuffer(frameBuffer, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cachedIsoTriangleCounts[idx] * 3)
        }
        return true
    }

    private struct DistanceCellCacheKey: Equatable {
        let a: SIMD3<UInt32>
        let b: SIMD3<UInt32>
        let c: SIMD3<UInt32>
    }

    private struct DistanceLineCacheKey: Equatable {
        let mode: String
        let selectedAtoms: [Int]
        let source: SIMD3<UInt32>
        let target: SIMD3<UInt32>
        let cell: DistanceCellCacheKey?
        let periodicDim: Int
        let resultMode: String
        let resultAtomIndices: [Int]
        let resultValue: UInt32
        let resultSummary: String
    }

    private static func distanceLineCacheKey(for scene: Scene) -> DistanceLineCacheKey? {
        let selected = scene.selectedAtoms
        guard scene.measurementMode == .distance,
              selected.count == 2,
              let result = scene.measurementResult,
              result.mode == .distance,
              result.atomIndices == selected,
              result.value.isFinite else { return nil }

        let atoms = scene.atoms
        let sourceIndex = selected[0], targetIndex = selected[1]
        guard sourceIndex >= 0, sourceIndex < atoms.count,
              targetIndex >= 0, targetIndex < atoms.count else { return nil }
        let source = atoms[sourceIndex].coord
        let target = atoms[targetIndex].coord
        let cell = scene.cell.map {
            DistanceCellCacheKey(a: floatBits($0.a), b: floatBits($0.b), c: floatBits($0.c))
        }
        return DistanceLineCacheKey(
            mode: scene.measurementMode.rawValue,
            selectedAtoms: selected,
            source: floatBits(source),
            target: floatBits(target),
            cell: cell,
            periodicDim: scene.periodicDim,
            resultMode: result.mode.rawValue,
            resultAtomIndices: result.atomIndices,
            resultValue: result.value.bitPattern,
            resultSummary: result.summary
        )
    }

    private static func floatBits(_ value: SIMD3<Float>) -> SIMD3<UInt32> {
        SIMD3(value.x.bitPattern, value.y.bitPattern, value.z.bitPattern)
    }

    // Per-shell isosurface cache (index 0 = outside/sign>0, 1 = inside/sign<0).
    // Polyhedral cache: reuses vertex buffer across camera-only frames.
    private var cachedPolyBuffer: MTLBuffer?
    private var cachedPolyVertexCount: Int = 0
    private var cachedPolyKey: (atoms: [Atom], bonds: [Bond], selected: [Int],
                                coordinationNumbers: [Int], showCoordinationColors: Bool,
                                atomColorScheme: AtomColorScheme, atomScale: Float,
                                elementOverridesFP: UInt64)?

    // Transparent polyhedral cache: the world-space triangle geometry is static
    // (camera-independent), so per-atom triangle lists are cached keyed exactly like
    // the opaque polyhedral cache. Per frame, only the structure clip cull is applied
    // and the visible triangles are depth-sorted + repacked — the expensive
    // polyhedronFaces/normal/color work is done once per cache key, not per frame.
    private var cachedTransparentPoly: TransparentPolyCache?
    private struct PolyVert { var x: Float; var y: Float; var z: Float; var nx: Float; var ny: Float; var nz: Float; var r: Float; var g: Float; var b: Float }
    private struct TransparentTri { var v0: PolyVert; var v1: PolyVert; var v2: PolyVert; var centroid: SIMD3<Float> }
    private struct TransparentPolyCache {
        var atoms: [Atom]
        var bonds: [Bond]
        var selected: [Int]
        var coordinationNumbers: [Int]
        var showCoordinationColors: Bool
        var atomColorScheme: AtomColorScheme
        var atomScale: Float
        var elementOverridesFP: UInt64
        // atomTris[i] holds the static triangles built from atom i's neighbors; empty
        // for atoms with too few neighbors. Per-frame culling skips whole atoms.
        var atomTris: [[TransparentTri]]
    }

    // One-entry distance cache. An optional vertex array distinguishes a cached
    // malformed-geometry failure from an uncached key, so failed periodic solves
    // are not retried on every camera redraw.
    private var cachedDistanceLineKey: DistanceLineCacheKey?
    private var cachedDistanceLineVertices: [SIMD3<Float>]?
    private(set) var distanceLineResolveCount = 0

    private var cachedIsoBuffers: [MTLBuffer?] = []
    private var cachedIsoKeys: [IsoCacheKey?] = []
    private var cachedIsoTriangleCounts: [Int] = []
    /// Snapshot of the iso spec list + clip plane at the last rebuild, so a spec
    /// list or clip change triggers a full shell rebuild (the dynamic caches
    /// can't resize from a fixed key comparison alone).
    private var cachedIsoSpecSignature: [IsoSurfaceSpec] = []
    private var cachedIsoClip: ClipPlane?
    private(set) var isoRebuildCount = 0

    // MARK: - Fermi surface (multi-band isosurface at the Fermi level)

    /// Per-band Fermi-surface mesh cache. One slot per source band, INCLUDING a
    /// nil/no-crossing band (`triangleCount == 0`). Keeping nil slots means the
    /// slot count always equals `fs.bands.count`, so the rebuild guard fires only
    /// when the band COUNT changes — a noncrossing band no longer forces a
    /// rebuild every frame. The previous `[MTLBuffer]` dropped nils via
    /// `compactMap`, shrinking the count and defeating the guard.
    private var cachedFermiBuffers: [MTLBuffer?] = []
    /// Clip signature at the last Fermi rebuild; when it changes the per-band
    /// buffers are rebuilt so the clipped meshes refresh.
    private var cachedFermiClip: ClipPlane?
    /// Per-atom structure-cull flags for the current drawScene pass. Empty when no
    /// structure clip is active (or in 2D modes). Recomputed at the top of drawScene.
    private var frameStructureCull: [Bool] = []
    /// Translational-asymmetric-unit cull flags for this frame. True means the atom
    /// lies outside the base cell and must be dropped. Empty (no culling) unless
    /// `repetitionMode == .translationalAsymmetricUnit` with no supercell.
    private var frameRepetitionCull: [Bool] = []

    // MARK: - Molecular (solvent-accessible) surface cache

    /// Cached GPU mesh for the molecular surface, keyed by (atom fingerprint,
    /// probe radius, color, opacity). Rebuilt only when its inputs change.
    private var cachedMolSurface: MolSurfaceCache?
    private struct MolSurfaceCache {
        var atomFP: UInt64
        var elementOverridesFP: UInt64
        var probeRadius: Float
        var color: SIMD3<Float>
        var opacity: Float
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
    }

    // MARK: - Volume slice texture cache

    /// One cached slice texture per enabled VolumeSlice. The key is
    /// (field generation, slice params, colormap) so a change to any of those
    /// rebuilds the texture. Nil textures are not cached (malformed planes are
    /// skipped every frame).
    private var cachedSliceTextures: [MTLTexture?] = []
    private var cachedSliceKeys: [SliceTextureKey?] = []

    /// Key for a cached volume slice texture.
    struct SliceTextureKey: Equatable {
        var h: Int, k: Int, l: Int
        var distance: Float
        var generation: UInt64
        var colormapRaw: String
    }

    /// Color-plane (2D grid) compositing texture cache. One slot, keyed by the grid
    /// geometry + colormap + the base address of the RETAINED flat copy (stable for the
    /// renderer's lifetime — never the transient per-frame flat, whose reused malloc
    /// address would alias a stale texture). A cache hit also requires the retained flat's
    /// content to equal the incoming grid content, compared via CoW storage identity or
    /// exact == against the retained copy.
    private var cachedColorPlaneTexture: MTLTexture?
    private var cachedColorPlaneKey: ColorPlaneTextureKey?
    private var cachedColorPlaneFlat: [Float]?

    struct ColorPlaneTextureKey: Equatable {
        var cols: Int, rows: Int
        var origin: SIMD3<Float>
        var vec0: SIMD3<Float>, vec1: SIMD3<Float>
        var valueBase: UnsafeRawPointer?   // base of RETAINED flat, never a scoped temporary
        var colormapRaw: String
    }

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
        let clip = isoClipPlane()
        // Rebuild when the band COUNT changes OR the clip plane changes. Because
        // cachedFermiBuffers keeps one slot per band (nil for a no-crossing band),
        // the slot count always equals fs.bands.count after the first build — a
        // noncrossing band therefore never triggers a rebuild by count alone.
        if cachedFermiBuffers.count != fs.bands.count || cachedFermiClip != scene.clipPlane {
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
                // Apply the clipping plane to the band mesh when active.
                let clipped: FieldSlice.ClippedMesh
                if let clip {
                    clipped = FieldSlice.clipTrianglesWithOverflow(mesh.vertices, plane: clip, keepSide: 1)
                } else {
                    clipped = FieldSlice.ClippedMesh(vertices: mesh.vertices, overflow: false)
                }
                // A clipped band that overflowed the 5M-triangle cap is a truncated surface
                // — never cache or render it as complete. Surface the failure so the frame
                // drops rather than silently drawing a truncated band, mirroring the
                // IsoMesh.overflow check above.
                if clipped.overflow {
                    ok = false
                    break
                }
                let verts = clipped.vertices
                if !verts.isEmpty {
                    // A non-empty band that fails to allocate must not commit a partial
                    // array (its length would then match fs.bands.count and defeat the
                    // rebuild guard, silently dropping that band). Abort and surface it.
                    if let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.stride, options: []) {
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
            cachedFermiClip = scene.clipPlane
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

    // MARK: - Volume slice texture generation

    /// Pure helper: convert a sampled slice's values + mask + colormap into RGBA8
    /// bytes. Alpha 0 where the mask is false (masked sample); alpha 255 where
    /// valid (mask true or mask==nil meaning all valid). Exposed for tests.
    static func sliceTextureBytes(values: [Float], mask: [Bool]?, minValue: Float,
                                  maxValue: Float, colormap: Colormap) -> [UInt8] {
        let count = values.count
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let range = maxValue - minValue
        guard range > 1e-9 else {
            // Constant field: every sample maps to the same color.
            let (r, g, b) = colormap.rgb8(minValue)
            for i in 0..<count {
                let valid = mask?[i] ?? true
                let o = i * 4
                bytes[o] = r; bytes[o+1] = g; bytes[o+2] = b
                bytes[o+3] = valid ? 255 : 0
            }
            return bytes
        }
        for i in 0..<count {
            let t = (values[i] - minValue) / range
            let (r, g, b) = colormap.rgb8(t)
            let valid = mask?[i] ?? true
            let o = i * 4
            bytes[o] = r; bytes[o+1] = g; bytes[o+2] = b
            bytes[o+3] = valid ? 255 : 0
        }
        return bytes
    }

    /// Build (or reuse) the RGBA8 texture for one volume slice. Returns nil for a
    /// malformed plane (fromFractional/sample nil) or an allocation failure. The
    /// texture is cached per (field generation, slice params, colormap).
    private func textureForVolumeSlice(_ slice: VolumeSlice, field: ScalarField,
                                       colormap: Colormap) -> MTLTexture? {
        let key = SliceTextureKey(h: slice.h, k: slice.k, l: slice.l,
                                  distance: slice.distance,
                                  generation: sliceFieldGeneration,
                                  colormapRaw: colormap.rawValue)
        // Find the matching cached slot by key identity (the slice list order is
        // stable, but a slice may be toggled/disabled, so we rebuild per-frame).
        for (idx, cached) in cachedSliceKeys.enumerated() {
            if cached == key, let tex = cachedSliceTextures[idx] { return tex }
        }
        // Rebuild: sample the field on the fractional plane.
        guard let cell = scene.cell else { return nil }
        guard let plane = SlicePlane.fromFractional(h: slice.h, k: slice.k, l: slice.l,
                                                     distance: slice.distance, cell: cell) else {
            return nil
        }
        guard let sampled = FieldSlice.sample(field: field, plane: plane, resolution: 96) else {
            return nil
        }
        let bytes = Renderer.sliceTextureBytes(values: sampled.values, mask: sampled.mask,
                                                minValue: sampled.minValue, maxValue: sampled.maxValue,
                                                colormap: colormap)
        let w = sampled.cols, h = sampled.rows
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w
        desc.height = h
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: w * 4)
        // Cache into the first free slot or append.
        if let free = cachedSliceTextures.firstIndex(where: { $0 == nil }) {
            cachedSliceTextures[free] = tex
            cachedSliceKeys[free] = key
        } else {
            cachedSliceTextures.append(tex)
            cachedSliceKeys.append(key)
        }
        return tex
    }

    // MARK: - Volume slice drawing

    /// Draw enabled volume slices as textured quads in the Metal scene. Composited
    /// with structure/isosurfaces via depth testing. Skips malformed planes and
    /// 2D display modes. Draws after Fermi, before the color plane.
    @discardableResult
    private func drawVolumeSlices(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard !scene.displayMode.is2D else { return true }
        guard let field = scene.scalarField else { return true }
        let slices = scene.volumeSlices
        guard !slices.isEmpty else { return true }
        // Resize caches to match the slice count.
        if cachedSliceTextures.count != slices.count {
            cachedSliceTextures = [MTLTexture?](repeating: nil, count: slices.count)
            cachedSliceKeys = [SliceTextureKey?](repeating: nil, count: slices.count)
        }
        enc.setRenderPipelineState(texQuadPipeline)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentSamplerState(texQuadSampler, index: 0)
        for (idx, slice) in slices.enumerated() {
            guard slice.enabled else { continue }
            guard let tex = textureForVolumeSlice(slice, field: field,
                                                  colormap: scene.colorPlaneColormap) else {
                continue
            }
            // Find the cached slice geometry to position the quad.
            guard let cell = scene.cell,
                  let plane = SlicePlane.fromFractional(h: slice.h, k: slice.k, l: slice.l,
                                                         distance: slice.distance, cell: cell),
                  let sampled = FieldSlice.sample(field: field, plane: plane, resolution: 96) else {
                continue
            }
            // Quad corners: origin, origin+vec0*(cols-1), origin+vec1*(rows-1),
            // origin+vec0*(cols-1)+vec1*(rows-1). uv 0...1.
            let o = sampled.origin
            let c01 = o + sampled.vec[0] * Float(sampled.cols - 1)
            let c10 = o + sampled.vec[1] * Float(sampled.rows - 1)
            let c11 = o + sampled.vec[0] * Float(sampled.cols - 1)
                       + sampled.vec[1] * Float(sampled.rows - 1)
            // Two triangles: (o, c01, c10) and (c01, c11, c10).
            struct V { var pos: SIMD4<Float>; var uv: SIMD2<Float> }
            let verts: [V] = [
                V(pos: SIMD4(o.x, o.y, o.z, 1),   uv: SIMD2(0, 0)),
                V(pos: SIMD4(c01.x, c01.y, c01.z, 1), uv: SIMD2(1, 0)),
                V(pos: SIMD4(c10.x, c10.y, c10.z, 1), uv: SIMD2(0, 1)),
                V(pos: SIMD4(c01.x, c01.y, c01.z, 1), uv: SIMD2(1, 0)),
                V(pos: SIMD4(c11.x, c11.y, c11.z, 1), uv: SIMD2(1, 1)),
                V(pos: SIMD4(c10.x, c10.y, c10.z, 1), uv: SIMD2(0, 1)),
            ]
            guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else {
                return false
            }
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return true
    }

    // MARK: - Color-plane compositing (2D grid as a textured quad in 3D scene)

    /// Build (or reuse) the RGBA8 texture for the 2D grid composited in the 3D
    /// scene. Row-major grid.values -> flat RGBA8 via the scene's colormap.
    /// Texture cache keyed by (grid storage identity / content, colormap).
    private func textureForColorPlane(grid: Grid2D, colormap: Colormap) -> MTLTexture? {
        let flat = grid.values.flatMap { $0 }
        guard !flat.isEmpty else { return nil }
        // Key on the RETAINED flat's base address (stable for the renderer's lifetime),
        // never the transient per-frame flat, whose reused malloc address would alias a
        // stale texture across frames.
        let valueBase = cachedColorPlaneFlat?.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        let key = ColorPlaneTextureKey(cols: grid.cols, rows: grid.rows,
                                       origin: grid.origin, vec0: grid.vec[0], vec1: grid.vec[1],
                                       valueBase: valueBase,
                                       colormapRaw: colormap.rawValue)
        // Hit only when the key matches AND the retained flat's content equals the incoming
        // grid content. Content is compared via CoW storage identity (O(1)) or exact ==
        // when storage differs — rebuilding the texture ONLY on a real content change.
        if cachedColorPlaneKey == key, let tex = cachedColorPlaneTexture,
           sameValueStorage(cachedColorPlaneFlat ?? [], flat) {
            return tex
        }
        // Content changed or first build: encode a fresh texture and retain its flat.
        cachedColorPlaneFlat = flat
        let bytes = Renderer.colorPlaneTextureBytes(grid: grid, colormap: colormap)
        let w = grid.cols, h = grid.rows
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w
        desc.height = h
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: w * 4)
        cachedColorPlaneTexture = tex
        cachedColorPlaneKey = key
        return tex
    }

    /// Pure helper: convert a 2D grid's values + colormap into RGBA8 bytes.
    /// Row-major grid.values -> flat RGBA8 (all valid, alpha 255).
    static func colorPlaneTextureBytes(grid: Grid2D, colormap: Colormap) -> [UInt8] {
        let w = grid.cols, h = grid.rows
        let range = grid.maxValue - grid.minValue
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard range > 1e-9 else {
            let (r, g, b) = colormap.rgb8(grid.minValue)
            for i in 0..<(w * h) {
                let o = i * 4
                bytes[o] = r; bytes[o+1] = g; bytes[o+2] = b; bytes[o+3] = 255
            }
            return bytes
        }
        for row in 0..<h {
            for col in 0..<w {
                let t = (grid.values[row][col] - grid.minValue) / range
                let (r, g, b) = colormap.rgb8(t)
                let o = (row * w + col) * 4
                bytes[o] = r; bytes[o+1] = g; bytes[o+2] = b; bytes[o+3] = 255
            }
        }
        return bytes
    }

    /// Draw the 2D grid as a textured quad in world space inside the Metal scene.
    /// Contours are traced in 3D on the quad when enabled. Only in 3D display modes.
    @discardableResult
    private func drawColorPlane3D(_ enc: MTLRenderCommandEncoder, frameBuffer: MTLBuffer?) -> Bool {
        guard !scene.displayMode.is2D else { return true }
        guard let grid = scene.grid2D, scene.showColorPlane else { return true }
        guard let tex = textureForColorPlane(grid: grid, colormap: scene.colorPlaneColormap) else {
            return true
        }
        // Quad in world space: sample (col,row) at
        //   grid.origin + grid.vec[0]*col/(cols-1) + grid.vec[1]*row/(rows-1)
        let o = grid.origin
        let c01 = o + grid.vec[0] * Float(grid.cols - 1)
        let c10 = o + grid.vec[1] * Float(grid.rows - 1)
        let c11 = o + grid.vec[0] * Float(grid.cols - 1) + grid.vec[1] * Float(grid.rows - 1)
        struct V { var pos: SIMD4<Float>; var uv: SIMD2<Float> }
        let verts: [V] = [
            V(pos: SIMD4(o.x, o.y, o.z, 1),   uv: SIMD2(0, 0)),
            V(pos: SIMD4(c01.x, c01.y, c01.z, 1), uv: SIMD2(1, 0)),
            V(pos: SIMD4(c10.x, c10.y, c10.z, 1), uv: SIMD2(0, 1)),
            V(pos: SIMD4(c01.x, c01.y, c01.z, 1), uv: SIMD2(1, 0)),
            V(pos: SIMD4(c11.x, c11.y, c11.z, 1), uv: SIMD2(1, 1)),
            V(pos: SIMD4(c10.x, c10.y, c10.z, 1), uv: SIMD2(0, 1)),
        ]
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: []) else {
            return false
        }
        enc.setRenderPipelineState(texQuadPipeline)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 2)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(texQuadSampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Contour lines on top, traced in 3D on the quad.
        if scene.colorPlaneContourEnabled {
            drawColorPlaneContours3D(grid: grid, enc: enc, frameBuffer: frameBuffer)
        }
        return true
    }

    /// Trace contour lines in 3D on the color-plane quad. For each cell use
    /// ColorPlaneView.contourSegments, map cell-local (u,v) to world via the
    /// Grid2D mapping, draw with the existing line pipeline. Bounded: cap total
    /// segments (else skip contour drawing).
    private func drawColorPlaneContours3D(grid: Grid2D, enc: MTLRenderCommandEncoder,
                                          frameBuffer: MTLBuffer?) {
        let cols = grid.cols, rows = grid.rows
        guard cols > 1, rows > 1 else { return }
        let levels = ContourConfig.levels(min: grid.minValue, max: grid.maxValue,
                                          count: scene.colorPlaneContourCount)
        guard !levels.isEmpty else { return }
        let maxSegments = 200_000
        // Pre-count segments to avoid exceeding the cap.
        var totalSegs = 0
        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let tl = grid.values[row][col], tr = grid.values[row][col + 1]
                let br = grid.values[row + 1][col + 1], bl = grid.values[row + 1][col]
                for level in levels {
                    totalSegs += ColorPlaneView.contourSegments(tl: tl, tr: tr, br: br, bl: bl, level: level).count
                    if totalSegs > maxSegments { return }
                }
            }
        }
        // Map cell-local (u,v) in [0,1]² to world position.
        func world(u: Float, v: Float) -> SIMD3<Float> {
            return grid.origin + grid.vec[0] * u + grid.vec[1] * v
        }
        var contourVerts: [SIMD3<Float>] = []
        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let tl = grid.values[row][col], tr = grid.values[row][col + 1]
                let br = grid.values[row + 1][col + 1], bl = grid.values[row + 1][col]
                for level in levels {
                    for seg in ColorPlaneView.contourSegments(tl: tl, tr: tr, br: br, bl: bl, level: level) {
                        let fu0 = (Float(col) + seg[0].x) / Float(cols - 1)
                        let fv0 = (Float(row) + seg[0].y) / Float(rows - 1)
                        let fu1 = (Float(col) + seg[1].x) / Float(cols - 1)
                        let fv1 = (Float(row) + seg[1].y) / Float(rows - 1)
                        contourVerts.append(world(u: fu0, v: fv0))
                        contourVerts.append(world(u: fu1, v: fv1))
                    }
                }
            }
        }
        if contourVerts.isEmpty { return }
        _ = drawLineBuffer(contourVerts, color: SIMD3<Float>(1, 1, 1), enc: enc, frameBuffer: frameBuffer)
    }

    /// Conditional cache invalidation. The renderer's `scene` is reassigned on
    /// EVERY sidebar change (the controller writes appearance fields into its
    /// Scene, which fires its own `scene.didSet → renderer.scene = scene`). Only
    /// invalidate a cache when its inputs actually changed — otherwise an
    /// appearance-only tweak (lighting, scales, background) rebuilds the BZ /
    /// iso / fermi caches every frame.
    private func invalidateCaches(old: Scene) {
        if Renderer.distanceLineCacheKey(for: old) != Renderer.distanceLineCacheKey(for: scene) {
            cachedDistanceLineKey = nil
            cachedDistanceLineVertices = nil
        }

        // AO/shadow cache: invalidate when quality levels change (coords are
        // checked inside computeAOShadowFactors via the cache key).
        if old.aoQuality != scene.aoQuality || old.shadowQuality != scene.shadowQuality {
            cachedAOShadowFactors = nil
            cachedAOShadowKey = nil
        }

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
        // Transparent polyhedral cache shares the same structural key; clear it on the
        // same atom/bond/selected changes. Guarded on the cache being populated so an
        // unrelated appearance tweak doesn't spuriously rebuild the geometry.
        if let oldTPoly = cachedTransparentPoly, oldTPoly.selected != scene.selectedAtoms
            || oldTPoly.atoms.count != scene.atoms.count
            || zip(oldTPoly.atoms, scene.atoms).contains(where: { $0.coord != $1.coord || $0.atomicNumber != $1.atomicNumber })
            || oldTPoly.bonds.count != scene.bonds.count
            || zip(oldTPoly.bonds, scene.bonds).contains(where: { $0.i != $1.i || $0.j != $1.j }) {
            cachedTransparentPoly = nil
        }
        if !isoInputsUnchanged(old: old) || old.isoSurfaces != scene.isoSurfaces || old.clipPlane != scene.clipPlane {
            // Content, geometry, iso level, spec list, or clip plane changed: any
            // existing mesh/vertex-data is stale. Bump the renderer-owned generation
            // so the per-frame IsoCacheKey comparison below forces a rebuild, and drop
            // the cached buffers/counts. Because content change is detected exactly via
            // CoW storage identity (see sameValueStorage), no O(n) scan happens on an
            // appearance-only edit where the field array storage is unchanged. Spec-list
            // and clip changes also clear the cached signature so drawIsosurface
            // rebuilds every shell against the new inputs.
            scalarFieldGeneration += 1
            cachedIsoBuffers = []
            cachedIsoKeys = []
            cachedIsoTriangleCounts = []
            cachedIsoSpecSignature = []
            cachedIsoClip = nil
        }
        // Slice textures sample the raw field (FieldSlice.sample ignores isoLevel and
        // clip), so they only rebuild when the field's geometry or content change —
        // never on a pure iso-level or clip-plane edit. Bumping a SEPARATE token keeps
        // iso/clip edits from throwing away cached slice textures. The slice plane is
        // positioned against the unit cell, so a lattice change (leaving the field
        // untouched) also shifts the sampled world-space plane and must rebuild them.
        if !scalarFieldContentUnchanged(old: old) || old.cell != scene.cell {
            sliceFieldGeneration += 1
        }
        if !fermiInputsUnchanged(old: old) || old.clipPlane != scene.clipPlane {
            // A Fermi band's content, geometry, band count, Fermi energy, or clip
            // plane changed: drop the cached per-band buffers. The per-frame rebuild
            // guard then sees the buffer count fall below fs.bands.count (or the clip
            // signature differ) and rebuilds. Per-band content change is detected
            // exactly via CoW storage identity.
            cachedFermiBuffers = []
            cachedFermiClip = nil
        }
        // Volume slice textures: invalidate when the slice params or colormap change.
        // A change in the slice list count, params, or colormap rebuilds next frame.
        let sliceParamsChanged = old.volumeSlices != scene.volumeSlices
            || old.colorPlaneColormap != scene.colorPlaneColormap
        if sliceParamsChanged {
            cachedSliceTextures = []
            cachedSliceKeys = []
        }
        // Color-plane compositing texture: invalidate when the grid content/colormap
        // changes. A nil/absent grid, or a grid value change, rebuilds next frame.
        let colorPlaneChanged = !colorPlaneInputsUnchanged(old: old)
            || old.colorPlaneColormap != scene.colorPlaneColormap
        if colorPlaneChanged {
            cachedColorPlaneTexture = nil
            cachedColorPlaneKey = nil
            cachedColorPlaneFlat = nil
        }
        // Background image: invalidate when the path changes so the next frame
        // reloads (or clears) the texture AND the cached quad buffer.
        if old.backgroundImagePath != scene.backgroundImagePath {
            cachedBgImageTexture = nil
            cachedBgImagePath = nil
            cachedBgImageDevice = nil
            cachedBgQuadBuffer = nil
            cachedBgQuadKey = (0, 0, 0, 0)
        }
    }

    private func colorPlaneInputsUnchanged(old: Scene) -> Bool {
        let a = old.grid2D, b = scene.grid2D
        guard let a, let b else { return a == nil && b == nil }
        guard a.cols == b.cols, a.rows == b.rows, a.origin == b.origin, a.vec == b.vec else {
            return false
        }
        // Exact element-wise comparison. CoW storage-identity alone is unsound here: an
        // in-place value mutation that preserves row storage would be judged unchanged.
        // exact == catches every content drift (this runs only on scene reassignment, so
        // the O(n) scan is acceptable; the per-frame cache key relies on the retained flat).
        guard a.values.count == b.values.count else { return false }
        for (ra, rb) in zip(a.values, b.values) {
            if ra != rb { return false }
        }
        return true
    }

    private func isoInputsUnchanged(old: Scene) -> Bool {
        // Field geometry + content unchanged (see scalarFieldContentUnchanged) AND
        // the iso level unchanged — the iso shell is surfaced at this level, so a
        // level change rebuilds the shells but leaves slice textures cached.
        return scalarFieldContentUnchanged(old: old) && old.isoLevel == scene.isoLevel
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

    // MARK: - Iso spec / clip-plane helpers

    /// Parse a "#RRGGBB" (or "RRGGBB") hex string into a linear 0…1 SIMD3<Float>.
    /// Falls back to the classic cool-blue default on malformed input.
    static func colorFromHex(_ hex: String) -> SIMD3<Float> {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return SIMD3<Float>(0.30, 0.62, 0.95)
        }
        return SIMD3<Float>(Float((v >> 16) & 0xFF) / 255.0,
                           Float((v >> 8) & 0xFF) / 255.0,
                           Float(v & 0xFF) / 255.0)
    }

    /// The ordered list of shells to render this frame. Legacy (empty specs) → the
    /// classic ±isoLevel blue/orange pair; otherwise one shell per enabled spec.
    private func currentIsoShells() -> [(sign: Float, color: SIMD3<Float>)] {
        if scene.isoSurfaces.isEmpty {
            return [(1, SIMD3<Float>(0.30, 0.62, 0.95)),
                    (-1, SIMD3<Float>(0.95, 0.45, 0.25))]
        }
        return scene.isoSurfaces.filter { $0.enabled }.map { ($0.sign, Renderer.colorFromHex($0.colorHex)) }
    }

    /// The world-space clipping plane for isosurfaces this frame, or nil when no
    /// clip is active. Built from scene.clipPlane via the fractional→world helper.
    private func isoClipPlane() -> SlicePlane? {
        guard let clip = scene.clipPlane, clip.enabled, clip.applyToIsosurfaces,
              let cell = scene.cell else { return nil }
        return SlicePlane.fromFractional(h: clip.h, k: clip.k, l: clip.l,
                                         distance: clip.distance, cell: cell)
    }

    /// Fractional-space cull parameters for structure atoms, or nil when no
    /// structure clip is active. Returns the (hkl, distance) pair for the test
    /// `dot(frac, hkl) >= distance - 1e-4`.
    private func structureClipParams() -> (hkl: SIMD3<Float>, distance: Float)? {
        guard let clip = scene.clipPlane, clip.enabled, clip.applyToStructure,
              let cell = scene.cell else { return nil }
        let hkl = SIMD3<Float>(Float(clip.h), Float(clip.k), Float(clip.l))
        guard simd_length(hkl) > 1e-9 else { return nil }
        // Confirm the cell is non-singular (same guard as the slab convention).
        let det = simd_dot(cell.a, simd_cross(cell.b, cell.c))
        guard abs(det) >= 1e-6 else { return nil }
        return (hkl, clip.distance)
    }

    /// Per-atom cull flags for the active structure clip plane. Empty array when
    /// no structure clip is active (so callers can skip the cull test entirely).
    /// Test-only seam: pure function of scene state, asserted by Phase2aTests.
    func structureCullFlags() -> [Bool] {
        guard let cull = structureClipParams() else { return [] }
        let eps: Float = 1e-4
        return scene.atoms.map { a in
            guard let f = scene.fractionalCoord(a.coord),
                  f.x.isFinite, f.y.isFinite, f.z.isFinite else { return false }
            let proj = f.x * cull.hkl.x + f.y * cull.hkl.y + f.z * cull.hkl.z
            guard proj.isFinite else { return false }
            return proj < cull.distance - eps
        }
    }

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

    /// TexQuadIn: float4 position @0 (world-space xyz + w=1), float2 uv @1.
    /// float4 is 16 bytes, float2 is 8 bytes; stride = 24.
    private static func makeTexQuadVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float4
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride  // 16
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD4<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride  // 24
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

    /// BgImageIn / MergeIn: float2 position @0 (NDC -1…1), float2 uv @1.
    /// float2 is 8 bytes; stride = 16.
    private static func makeBgQuadVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride  // 8
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2  // 16
        return vd
    }

    /// Two triangles covering NDC (-1…1) with uv 0…1 for the anaglyph-merge
    /// fullscreen pass. The v mapping is INVERTED relative to a naive 0…1: in
    /// Metal, texture row 0 (v=0) is the TOP of the image, but NDC y=-1 is the
    /// BOTTOM of the screen. So screen-bottom (NDC -1) must sample the texture's
    /// bottom row (v=1), and screen-top (NDC +1) must sample the texture's top
    /// row (v=0). Without this flip the merged anaglyph output would render
    /// vertically upside-down.
    private static func makeBgQuadBuffer(_ device: MTLDevice) -> MTLBuffer? {
        struct V { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
        let verts: [V] = [
            V(pos: SIMD2(-1, -1), uv: SIMD2(0, 1)),
            V(pos: SIMD2( 1, -1), uv: SIMD2(1, 1)),
            V(pos: SIMD2(-1,  1), uv: SIMD2(0, 0)),
            V(pos: SIMD2(-1,  1), uv: SIMD2(0, 0)),
            V(pos: SIMD2( 1, -1), uv: SIMD2(1, 1)),
            V(pos: SIMD2( 1,  1), uv: SIMD2(1, 0)),
        ]
        return device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: [])
    }

    // MARK: - Tessellation rebuild

    /// Rebuild the shared sphere/cylinder geometry when `scene.tessellationFactor`
    /// changes. Keyed by factor so it runs at most once per change, never per
    /// frame. factor 0 keeps the legacy fixed counts (sphere 12/20, cylinder 12).
    private func rebuildGeometryIfNeeded() {
        let k = scene.tessellationFactor
        if k == tessellationBuiltFactor { return }
        tessellationBuiltFactor = k
        let sphereLat: Int, sphereLon: Int, cylRad: Int
        if k <= 0 {
            sphereLat = 12; sphereLon = 20; cylRad = 12
        } else {
            // Clamp lat >= 4 and lon >= 6 so small k (e.g. k = 1) can't produce a
            // degenerate sphere (a single lat band collapses to a point/line).
            sphereLat = max(4, min(k, 72))
            sphereLon = max(6, min(2 * k + 4, 72))
            cylRad = max(3, min(k, 48))
        }
        let sMesh = Geometry.unitSphere(latSegments: sphereLat, lonSegments: sphereLon)
        let cMesh = Geometry.unitCylinder(radialSegments: cylRad)
        guard
            let svb = Renderer.makeInterleavedBuffer(device, mesh: sMesh),
            let sib = device.makeBuffer(bytes: sMesh.indices,
                                       length: sMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: []),
            let cvb = Renderer.makeInterleavedBuffer(device, mesh: cMesh),
            let cib = device.makeBuffer(bytes: cMesh.indices,
                                       length: cMesh.indices.count * MemoryLayout<UInt16>.stride,
                                       options: [])
        else { return }
        sphereMesh = sMesh; sphereVB = svb; sphereIB = sib
        cylinderMesh = cMesh; cylinderVB = cvb; cylinderIB = cib
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

    // MARK: - Per-element display resolution

    /// Deterministic per-element display color: override colorHex wins over the
    /// CPK table, falling back to `ElementTable.color`.
    private func elementColor(_ z: Int) -> SIMD3<Float> {
        AtomSchemeMetrics.elementColor(z: z, overrides: scene.elementOverrides)
    }

    /// Display covalent radius with per-element override support.
    private func elementCovalentRadius(_ z: Int) -> Float {
        AtomSchemeMetrics.elementCovalentRadius(z: z, overrides: scene.elementOverrides)
    }

    /// Display van-der-Waals radius with per-element override support.
    private func elementVdwRadius(_ z: Int) -> Float {
        AtomSchemeMetrics.elementVdwRadius(z: z, overrides: scene.elementOverrides)
    }

    /// FNV-1a fingerprint of the displayed atom set (coords + atomic numbers).
    /// Cheap incremental-style hash; good enough to detect content changes for
    /// the molecular-surface cache key.
    private func atomFingerprint() -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for a in scene.atoms {
            h ^= UInt64(bitPattern: Int64(a.atomicNumber)); h = h &* 0x100000001b3
            h ^= UInt64(a.coord.x.bitPattern); h = h &* 0x100000001b3
            h ^= UInt64(a.coord.y.bitPattern); h = h &* 0x100000001b3
            h ^= UInt64(a.coord.z.bitPattern); h = h &* 0x100000001b3
        }
        return h
    }

    /// Compact, deterministic digest of the per-element overrides that affect
    /// geometry/color: a small FNV of sorted (z, colorHex, covalentRadius,
    /// vdwRadius) tuples. Cheap to recompute; folded into cache keys so the
    /// polyhedral and molecular-surface meshes rebuild when an override changes.
    private func elementOverridesFingerprint() -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for z in scene.elementOverrides.keys.sorted() {
            h ^= UInt64(bitPattern: Int64(z)); h = h &* 0x100000001b3
            let o = scene.elementOverrides[z]!
            if let hex = o.colorHex {
                for b in hex.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            }
            h ^= UInt64(o.covalentRadius?.bitPattern ?? 0); h = h &* 0x100000001b3
            h ^= UInt64(o.vdwRadius?.bitPattern ?? 0); h = h &* 0x100000001b3
        }
        return h
    }

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
