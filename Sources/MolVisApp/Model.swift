import Foundation
import simd
import AppKit

struct Atom: Codable, Equatable { var coord: SIMD3<Float>; var atomicNumber: Int; var label: String
    /// Optional force on this atom (eV/Å), parsed from a QE `Forces acting on atoms`
    /// block when present. Drives the force-arrow overlay.
    var force: SIMD3<Float>?
}
struct Bond: Codable, Equatable {
    var i: Int
    var j: Int
    /// Lattice translation selected for atom j. Zero means the direct pair is
    /// bonded; non-zero values are periodic-only matches outside the finite
    /// displayed image set. Explicit supercell copies are rebuilt as zero-image
    /// pairs, so only those direct endpoints are rendered.
    var image: SIMD3<Int64> = .zero

    init(i: Int, j: Int, image: SIMD3<Int64> = .zero) {
        self.i = i
        self.j = j
        self.image = image
    }

    private enum CodingKeys: String, CodingKey { case i, j, image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        i = try c.decode(Int.self, forKey: .i)
        j = try c.decode(Int.self, forKey: .j)
        image = try c.decodeIfPresent(SIMD3<Int64>.self, forKey: .image) ?? .zero
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(i, forKey: .i)
        try c.encode(j, forKey: .j)
        // Keep newly written state compact while allowing old states without an
        // image key to decode as the direct/home pair.
        if image != .zero { try c.encode(image, forKey: .image) }
    }
}
struct Cell:  Codable, Equatable { var a: SIMD3<Float>; var b: SIMD3<Float>; var c: SIMD3<Float> }

enum DisplayMode: String, Codable, CaseIterable {
    case ballStick, spaceFill, wireFrame, polyhedral, line2D, point2D, ballStick2D
    var label: String {
        switch self {
        case .ballStick: return "Ball & Stick"
        case .spaceFill: return "Space Fill (CPK)"
        case .wireFrame: return "Wireframe"
        case .polyhedral: return "Polyhedral"
        case .line2D: return "2D Line"
        case .point2D: return "2D Point"
        case .ballStick2D: return "2D Ball-Stick"
        }
    }
    var is2D: Bool { self == .line2D || self == .point2D || self == .ballStick2D }
}

// Equatable is synthesized (all fields are Int) so replication DIRECTION is
// compared, not just total count — 2×1×1 vs 1×2×1 must differ.
struct SuperCell: Codable, Equatable { var n1: Int = 1; var n2: Int = 1; var n3: Int = 1
    // Saturating product so a malicious/huge supercell can't trap Swift's Int.
    // `total > 1` comparisons at call sites still read correctly (Int.max > 1).
    var total: Int {
        let ab = n1.multipliedReportingOverflow(by: n2)
        guard !ab.overflow else { return Int.max }
        let abc = ab.partialValue.multipliedReportingOverflow(by: n3)
        return abc.overflow ? Int.max : abc.partialValue
    }
}

/// What the next atom click measures. Caps selection at the needed count.
enum MeasurementMode: String, Codable {
    case none      // no active measurement
    case distance  // pick 2 atoms
    case angle     // pick 3 (middle is the vertex)
    case dihedral  // pick 4 (ordered)
    var selectionCap: Int {
        switch self {
        case .none: return Int.max
        case .distance: return 2
        case .angle: return 3
        case .dihedral: return 4
        }
    }
    var label: String {
        switch self {
        case .none: return "Selection"
        case .distance: return "Distance"
        case .angle: return "Angle"
        case .dihedral: return "Dihedral"
        }
    }
}

/// Result of an explicit distance/angle/dihedral measurement, computed from
/// a specific set of selected atom indices.
struct MeasurementResult: Codable {
    let mode: MeasurementMode
    let atomIndices: [Int]      // atoms used, in pick order
    let value: Float            // Å for distance, degrees for angles
    /// Human-readable summary, e.g. "Distance (1-2): 1.234 Å".
    let summary: String
}

struct Plane: Codable, Equatable { var h: Int = 0; var k: Int = 1; var l: Int = 0; var distance: Float = 0 }

struct Slab: Codable, Equatable { var planeA: Plane = Plane(); var planeB: Plane = Plane() }

struct Camera: Codable {
    var center: SIMD3<Float> = SIMD3(0,0,0)
    var distance: Float = 20
    var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    // Orthographic is the default: it removes perspective foreshortening and is
    // the conventional projection for crystal/molecule illustrations.
    var perspective: Bool = false
}

enum ProjectionMode: Codable { case perspective, ortho }

enum BackgroundType: String, Codable {
    case solid         // single flat color (`background`)
    case gradient_top  // vertical gradient, `background` (top) → `backgroundBottom` (bottom)
    case image         // fullscreen image (backgroundImagePath), fallback to solid/gradient
}

/// Anaglyph stereo rendering modes. `off` preserves the original single-view
/// render exactly; the two active modes merge two eye views through per-channel
/// masks. Persisted via rawValue.
enum AnaglyphMode: Int, Codable {
    case off = 0
    case redCyan = 1
    case greenMagenta = 2
    var label: String {
        switch self {
        case .off: return "Off"
        case .redCyan: return "Red-Cyan"
        case .greenMagenta: return "Green-Magenta"
        }
    }
}

/// Per-mode channel selection masks for the anaglyph merge. The left eye
/// contributes only the channels where leftMask is true; the right eye
/// contributes only the channels where rightMask is true. Deterministic.
struct AnaglyphChannelMasks {
    let left: SIMD3<Float>
    let right: SIMD3<Float>
    static func forMode(_ mode: AnaglyphMode) -> AnaglyphChannelMasks {
        switch mode {
        case .off:
            return AnaglyphChannelMasks(left: SIMD3<Float>(1, 1, 1),
                                        right: SIMD3<Float>(0, 0, 0))
        case .redCyan:
            // Red-Cyan: left eye contributes red; right eye contributes green+blue (cyan).
            return AnaglyphChannelMasks(left: SIMD3<Float>(1, 0, 0),
                                        right: SIMD3<Float>(0, 1, 1))
        case .greenMagenta:
            // Green-Magenta: left eye contributes green; right eye contributes red+blue (magenta).
            return AnaglyphChannelMasks(left: SIMD3<Float>(0, 1, 0),
                                        right: SIMD3<Float>(1, 0, 1))
        }
    }
}

/// Adjustable Phong-material lighting.  Kept in Scene so it can be driven by
/// sidebar sliders and persisted in the state file.
struct Lighting: Codable {
    var ambient: Float = 0.35
    var diffuse: Float = 0.65
    var specular: Float = 0.0       // 0 == matty; >0 adds a specular highlight
    var shininess: Float = 16.0
    /// Spherical direction to the light (degrees); converted to a vector in the
    /// renderer so the user never sees raw trigonometry.
    var azimuth: Float = 225.0
    var elevation: Float = 45.0
}

/// UI-side MSAA multiplier for the Appearance sidebar picker. The raw value
/// IS the Metal sample count; `off` is 1 (no MSAA). `Scene.msaaSampleCount`
/// carries the raw Int per the integration contract.
enum MSAASampleCount: Int, CaseIterable {
    case off = 1, x2 = 2, x4 = 4, x8 = 8
    var label: String {
        switch self {
        case .off: return "Off"
        case .x2: return "2x"
        case .x4: return "4x"
        case .x8: return "8x"
        }
    }
}

struct ColorScheme: Codable { var mode: String = "atomic" }

/// How atoms are colored when a non-element scheme is active. `.elemental`
/// matches the current default exactly (CPK table + per-element overrides).
enum AtomColorScheme: String, Codable, CaseIterable {
    case elemental      // atom-colored: per-element overrides apply
    case coordination   // color by coordination number (grouped buckets)
    case slabFraction   // per-atom fractional position between slab planes
    case distanceProportional // color by signed distance to the slab planeA
    var label: String {
        switch self {
        case .elemental: return "Elemental"
        case .coordination: return "Coordination"
        case .slabFraction: return "Slab Fraction"
        case .distanceProportional: return "Plane Distance"
        }
    }
}

/// How the base unit cell content is displayed without a supercell.
enum RepetitionMode: String, Codable, CaseIterable {
    case unitCell      // current default: atoms within the base cell, periodic images at borders
    case asymmetricUnit // translational asymmetric unit only (base cell interior)
    var label: String {
        switch self {
        case .unitCell: return "Unit Cell"
        case .asymmetricUnit: return "Translational Asymmetric Unit"
        }
    }
}

/// One configurable light source. Empty `Scene.lights` = legacy single light
/// (exactly today's output); when non-empty the renderer uses these instead.
struct SceneLightSource: Codable, Equatable {
    var enabled: Bool = true
    var azimuth: Float = 225.0
    var elevation: Float = 45.0
    var intensity: Float = 1.0
    var colorHex: String = "#FFFFFF"
}

/// Per-element display overrides. nil fields inherit the fixed CPK table.
struct ElementOverride: Codable, Equatable {
    var colorHex: String?
    var covalentRadius: Float?
    var vdwRadius: Float?
    var labelOverride: String?
    var fontScale: Float?
}

/// H-bond display + detection criteria (XCrySDen parity).
struct HbondSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Maximum H…A distance in Å. Aligned with XCrySDen's default 2.5 Å pair search.
    var maxDistance: Float = 2.5
    /// Minimum D−H…A angle in degrees (180 = perfectly linear).
    var minAngleDegrees: Float = 120.0
    var colorHex: String = "#88CCFF"
}

/// Molecular (solvent-accessible style) surface settings.
struct MolecularSurfaceSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Probe sphere radius in Å (default ≈ a water molecule).
    var probeRadius: Float = 1.4
    var opacity: Float = 0.6
    var colorHex: String = "#B0BEC5"
}

/// One detected H bond: donor atom index, its bound hydrogen, acceptor atom.
/// `acceptorImage` is the world coordinate of the periodic image of the acceptor
/// that satisfied the H…A criteria (nil for non-crystal scenes where the home
/// copy is the one matched). The renderer draws the dashed bond from the
/// hydrogen to `acceptorImage ?? atoms[acceptor].coord` so crystalline lines
/// connect to the right copy.
struct HbondPair: Codable, Equatable {
    var donor: Int
    var hydrogen: Int
    var acceptor: Int
    var acceptorImage: SIMD3<Float>?
}

/// Publication-quality presets that set multiple rendering controls at once.
/// Each preset configures line width, opacity, depth cueing, AO, and shadows for
/// a common output target. `.default` preserves the original rendering exactly.
enum PublicationPreset: String, Codable, CaseIterable {
    case `default` = "default"
    case journal = "journal"
    case presentation = "presentation"
    case print = "print"
    var label: String {
        switch self {
        case .default: return "Default"
        case .journal: return "Journal (fine lines, subtle AO)"
        case .presentation: return "Presentation (bold lines)"
        case .print: return "Print (depth cueing, stronger shading)"
        }
    }
    /// Apply this preset's quality settings to the given scene.
    func apply(to scene: inout Scene) {
        switch self {
        case .default:
            scene.lineWidth = 1.0
            scene.opacity = 1.0
            scene.depthCueingStrength = 0.0
            scene.aoStrength = 0.0
            scene.shadowStrength = 0.0
            scene.aoQuality = 2
            scene.shadowQuality = 2
        case .journal:
            scene.lineWidth = 1.5
            scene.opacity = 1.0
            scene.depthCueingStrength = 0.0
            scene.aoStrength = 0.4
            scene.shadowStrength = 0.3
            scene.aoQuality = 2
            scene.shadowQuality = 2
        case .presentation:
            scene.lineWidth = 3.0
            scene.opacity = 1.0
            scene.depthCueingStrength = 0.0
            scene.aoStrength = 0.0
            scene.shadowStrength = 0.0
            scene.aoQuality = 2
            scene.shadowQuality = 2
        case .print:
            scene.lineWidth = 2.0
            scene.opacity = 1.0
            scene.depthCueingStrength = 0.35
            scene.aoStrength = 0.5
            scene.shadowStrength = 0.4
            scene.aoQuality = 3
            scene.shadowQuality = 3
        }
    }
}

/// One independently-colored isosurface shell. When `scene.isoSurfaces` is non-empty
/// the renderer draws EXACTLY the enabled specs (each at sign*level in its color);
/// when empty it falls back to the legacy ±isoLevel pair. A spec with sign 1 renders
/// faces where field > sign*level. Ignored (legacy path) when the list is empty;
/// lists longer than 8 specs are capped.
struct IsoSurfaceSpec: Codable, Equatable {
    var level: Float
    var colorHex: String
    var sign: Float
    var enabled: Bool
}

/// A display-only clipping plane (never mutates scene atoms). Fractional convention
/// identical to Slab: keep points with h*x+k*y+l*z >= distance in fractional coords.
/// Only meaningful when scene.cell != nil.
struct ClipPlane: Codable, Equatable {
    var enabled: Bool = false
    var h: Int = 0
    var k: Int = 1
    var l: Int = 0
    var distance: Float = 0
    var applyToStructure: Bool = true
    var applyToIsosurfaces: Bool = true
}

/// A 3D volume slice: sample the scalar field on an arbitrary fractional plane
/// and draw it as a textured quad in the Metal scene. Fractional convention
/// identical to ClipPlane/Slab (h*x+k*y+l*z >= distance; the plane itself is
/// h*x+k*y+l*z == distance). Capped at 3 slices.
struct VolumeSlice: Codable, Equatable {
    var enabled: Bool = true
    var h: Int = 0
    var k: Int = 0
    var l: Int = 1
    var distance: Float = 0.5
}

/// Interactive camera orientation for the 3D band-surface plot. Persisted on the
/// Scene (optional, decode-if-present) so a saved state restores the user's view.
/// When nil the plot uses its built-in defaults (azimuth 30°, elevation 24°).
struct BandSurfaceOrientation: Codable, Equatable {
    var azimuthDegrees: Float = 30
    var elevationDegrees: Float = 24
}

struct Scene: Codable {
    var atoms: [Atom] = []
    var bonds: [Bond] = []
    var cell: Cell?
    var title: String = ""
    var displayMode: DisplayMode = .ballStick
    var isCrystal: Bool = false
    var periodicDim: Int = 3
    var superCell: SuperCell = SuperCell()
    /// The pristine atom set and bond set BEFORE any supercell expansion.
    /// `widenSuperCell` always builds from these so it can both grow and
    /// shrink — otherwise a reduction would have no way to recover the
    /// original atoms.
    var baseAtoms: [Atom] = []
    var baseBonds: [Bond] = []
    /// The widened atom set BEFORE slab filtering.  Set by `widenSuperCell`
    /// so `applySlab` always filters a fresh set rather than compounding
    /// on a previously-filtered result.
    var preslabAtoms: [Atom] = []
    var slab: Slab?
    /// An optional display-only clipping plane. nil = no clipping. When present
    /// and enabled, culls structure atoms/isosurfaces behind the plane. Only
    /// meaningful when scene.cell != nil.
    var clipPlane: ClipPlane?
    /// An optional volumetric scalar grid (a DATAGRID block read from an XSF file).
    /// Feeds the isosurface engine; nil for structure-only files.
    var scalarField: ScalarField?
    /// An optional Fermi surface (a parsed BXSF file): Fermi energy plus one grid
    /// per band, each surfaced as an isosurface AT the Fermi level. Rendered as a
    /// multi-band cage; nil for non-fermionic files.
    var fermiSurface: FermiSurface?
    /// Indices (into `atoms`) of atoms the user has selected by clicking.
    var selectedAtoms: [Int] = []
    /// Active measurement mode (drives selection cap + what labels show).
    var measurementMode: MeasurementMode = .none
    /// The result of the last explicit measurement (non-nil => locked: no
    /// new atoms can be selected until the user re-toggles a mode).
    var measurementResult: MeasurementResult?
    var backgroundType: BackgroundType = .solid
    var background: String = "#101014"
    var backgroundBottom: String = "#000000"   // gradient end color
    /// Optional path to a background image file. When backgroundType == .image
    /// and this is non-nil, the renderer draws the image as a fullscreen quad.
    /// nil (or an empty string on restore) means no image.
    var backgroundImagePath: String? = nil
    /// Anaglyph stereo rendering mode. Default .off preserves the original
    /// single-view render exactly (byte-identical output).
    var anaglyphMode: AnaglyphMode = .off
    /// The effective clear color derived from the background settings. Used as a
    /// fallback when no explicit export background override is supplied.
    var clearColor: (r: Double, g: Double, b: Double, a: Double) {
        let hex = backgroundType == .gradient_top ? backgroundBottom : background
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0, 1) }
        return (Double((v >> 16) & 0xFF) / 255.0,
                Double((v >> 8) & 0xFF) / 255.0,
                Double(v & 0xFF) / 255.0, 1)
    }
    var lighting: Lighting = Lighting()
    var showCellFrame: Bool = true
    var showAxes: Bool = true
    var showLabels: Bool = false
    /// Show live distance text above each displayed bond. Defaults off to
    /// preserve existing visuals; the label overlay draws the text at the
    /// projected bond midpoint with a small background chip.
    @DefaultFalse var showBondDistances: Bool = false
    /// Show the scale indicator overlay. Defaults off to preserve existing visuals.
    @DefaultFalse var showScaleIndicator: Bool = false
    /// Hide the atomic structure (atoms/bonds/polyhedra), keeping the cell
    /// frame, axes and Brillouin-zone overlay. Lets the user focus on the BZ.
    var showStructure: Bool = true
    /// Overlay the Brillouin-zone wireframe (crystal only) as a scene layer,
    /// drawn after the structure with depth so it sits correctly around it.
    var showBrillouinZone: Bool = false
    var atomScale: Float = 0.35
    var bondRadius: Float = 0.10
    var currentFrame: Int = 0      // AXSF animation frame index (GUI only)
    var camera: Camera = Camera()

    // Isosurface controls. `isoLevel` is an absolute field value; the sidebar
    /// slider runs over the field's [minValue, maxValue] range. `showIsoSurface`
    /// is gated in the UI on the presence of a scalarField.
    var showIsoSurface: Bool = true
    var isoLevel: Float = 0
    /// Multiple independent isosurface specs. Empty = legacy behavior (two
    /// complementary shells at +isoLevel/-isoLevel with cool-blue/warm-orange
    /// colors). Non-empty = render EXACTLY the enabled specs. Capped at 8.
    var isoSurfaces: [IsoSurfaceSpec] = []
    /// Overlay a Fermi surface (one isosurface per band at the Fermi level). Gated
    /// in the UI on the presence of a fermiSurface and drawn separately from the
    /// scalar-field isosurface so it can be toggled independently.
    var showFermiSurface: Bool = true
    /// A parsed band structure (k-points + eigenvalues), when the loaded file
    /// carried `bands (ev):` data (QE PWscf output). Gated in the UI on its
    /// presence; when set, the 2D Grapher replaces the 3D canvas.
    var bandStructure: BandStructure?
    /// Total and projected density-of-states data. When present, the DOS graph
    /// replaces the structure, band, and color-plane canvases.
    var densityOfStates: DensityOfStates?
    /// Multiple orbital grids from a multi-orbital Gaussian `.cube`/`.g98` file.
    /// When present, `scalarField` is the currently-selected orbital and the
    /// `currentOrbital` index picks which one. Empty for single-orbital files.
    var multiOrbitalFields: [ScalarField] = []
    /// Index of the currently displayed orbital into `multiOrbitalFields`.
    /// Ignored when `multiOrbitalFields` is empty (single-orbital case).
    var currentOrbital: Int = 0
    /// An optional 2D scalar grid (a `DATAGRID_2D` block), the color-plane source.
    /// Gated in the UI on its presence; when the color-plane is toggled on, the
    /// 2D ColorPlaneView replaces the 3D canvas with a value→color map + contours.
    var grid2D: Grid2D?
    /// Parsed forces/stress/energy from a QE output (final SCF iteration). Gated in
    /// the UI on its presence: a sidebar toggle draws force arrows and a readout.
    var forceSet: ForceSet?
     /// Draw force arrows (when `forceSet` is present). Gated in the UI on the
     /// presence of a forceSet; the renderer scales each arrow by `forceScale`.
     var showForces: Bool = false
      /// Toggle the color-plane overlay (DATAGRID_2D only). When on, the 2D
      /// ColorPlaneView replaces the 3D canvas; gated in the UI on `grid2D != nil`.
      @DefaultTrue var showColorPlane: Bool = true
    /// Precomputed 3D band-surface sheets (--band-surf) built from a uniform
    /// k-point mesh near the Fermi level. Gated in the UI on its presence.
    var bandSurface: BandSurface? = nil
    /// Whether the band-surface plot is displayed when `bandSurface` is present.
    @DefaultTrue var showBandSurface: Bool = true
    /// Persisted interactive orientation of the 3D band-surface plot. Optional so
    /// state files written before this field existed still decode (to nil/defaults).
    var bandSurfaceOrientation: BandSurfaceOrientation? = nil
    /// Colormap for the 2D color plane. Defaults to .viridis (byte-identical output).
    var colorPlaneColormap: Colormap = .viridis
    /// Whether contour lines are drawn over the color plane.
    var colorPlaneContourEnabled: Bool = true
    /// Number of contour levels (clamped 2...20). Used when contour is enabled.
    var colorPlaneContourCount: Int = 6
    /// 3D volume slices: sample the scalar field on arbitrary fractional planes
    /// and draw them as textured quads in the Metal scene. Empty = none; cap 3.
    var volumeSlices: [VolumeSlice] = []
    /// Multiplier converting a force (eV/Å) to an arrow length (Å) so typical
    /// forces (0.01–1 eV/Å) span a few Å and read clearly. Sidebar-adjustable.
    var forceScale: Float = 50.0
    /// MSAA sample count for the Metal render target. Valid values are 1, 2, 4, 8
    /// (default 1 = off). Driven by the Appearance sidebar picker; persisted as
    /// the flat JSON key `msaaSampleCount` in the state file.
    var msaaSampleCount: Int = 1
    /// The user-edited reciprocal-space k-path: an ordered list of special
    /// k-points (fractional, conventional reciprocal basis) connecting BZ
    /// landmarks. Empty for non-crystal scenes; for crystals it defaults to the
    /// generated high-symmetry path (see Scene.init) until the user edits it.
    var kPathPoints: [KPoint] = []
    /// Indices i such that there is NO segment between kPathPoints[i] and
    /// kPathPoints[i+1]. Represents disconnected high-symmetry segments (e.g.
    /// Γ-H-N | Γ-P for bcc). Empty for a fully connected path. Synced with the
    /// sidebar editor and persisted in the state file.
    var kPathBreaks: Set<Int> = []
    /// Provenance of the k-path: auto-generated (canonical) or user-edited.
    /// Drives regeneration behavior: generated paths are regenerated when the
    /// underlying structure changes; user-edited paths are preserved.
    var kPathProvenance: KPathProvenance = .generated
    /// Signature of the structure the kPath was generated from. Used to detect
    /// when regeneration is needed. Format: "spaceGroup|a|b|c|alpha|beta|gamma"
    /// from the standardized lattice. nil when the path is user-edited or no
    /// path has been generated.
    var kPathSignature: String? = nil
    /// Runtime-only symmetry analysis of the pristine 3D periodic structure.
    /// It is intentionally excluded from synthesized Scene persistence.
    @NonPersisted var crystalSymmetry: CrystalSymmetryAnalysis?

    // A custom decoder so that project files produced by older builds — which are
    // missing any field added since they were written — decode to each field's
    // declared default instead of throwing `keyNotFound`. Encoding is left to
    // the synthesized `encode(to:)` (camelCase keys, byte-identical output).
    // Matches the synthesized memberwise `init()` that this custom decoder
    // otherwise suppresses; all stored properties default-initialize correctly.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        atoms = try c.decodeIfPresent([Atom].self, forKey: .atoms) ?? []
        bonds = try c.decodeIfPresent([Bond].self, forKey: .bonds) ?? []
        cell = try c.decodeIfPresent(Cell.self, forKey: .cell) ?? nil
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .ballStick
        isCrystal = try c.decodeIfPresent(Bool.self, forKey: .isCrystal) ?? false
        periodicDim = try c.decodeIfPresent(Int.self, forKey: .periodicDim) ?? 3
        superCell = try c.decodeIfPresent(SuperCell.self, forKey: .superCell) ?? SuperCell()
        baseAtoms = try c.decodeIfPresent([Atom].self, forKey: .baseAtoms) ?? []
        baseBonds = try c.decodeIfPresent([Bond].self, forKey: .baseBonds) ?? []
        preslabAtoms = try c.decodeIfPresent([Atom].self, forKey: .preslabAtoms) ?? []
        slab = try c.decodeIfPresent(Slab.self, forKey: .slab) ?? nil
        clipPlane = try c.decodeIfPresent(ClipPlane.self, forKey: .clipPlane) ?? nil
        scalarField = try c.decodeIfPresent(ScalarField.self, forKey: .scalarField) ?? nil
        fermiSurface = try c.decodeIfPresent(FermiSurface.self, forKey: .fermiSurface) ?? nil
        selectedAtoms = try c.decodeIfPresent([Int].self, forKey: .selectedAtoms) ?? []
        measurementMode = try c.decodeIfPresent(MeasurementMode.self, forKey: .measurementMode) ?? .none
        measurementResult = try c.decodeIfPresent(MeasurementResult.self, forKey: .measurementResult) ?? nil
        backgroundType = try c.decodeIfPresent(BackgroundType.self, forKey: .backgroundType) ?? .solid
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "#101014"
        backgroundBottom = try c.decodeIfPresent(String.self, forKey: .backgroundBottom) ?? "#000000"
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath) ?? nil
        anaglyphMode = try c.decodeIfPresent(AnaglyphMode.self, forKey: .anaglyphMode) ?? .off
        lighting = try c.decodeIfPresent(Lighting.self, forKey: .lighting) ?? Lighting()
        showCellFrame = try c.decodeIfPresent(Bool.self, forKey: .showCellFrame) ?? true
        showAxes = try c.decodeIfPresent(Bool.self, forKey: .showAxes) ?? true
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? false
        showBondDistances = (try c.decode(DefaultFalse.self, forKey: .showBondDistances)).wrappedValue
        showScaleIndicator = (try c.decode(DefaultFalse.self, forKey: .showScaleIndicator)).wrappedValue
        showStructure = try c.decodeIfPresent(Bool.self, forKey: .showStructure) ?? true
        showBrillouinZone = try c.decodeIfPresent(Bool.self, forKey: .showBrillouinZone) ?? false
        atomScale = try c.decodeIfPresent(Float.self, forKey: .atomScale) ?? 0.35
        bondRadius = try c.decodeIfPresent(Float.self, forKey: .bondRadius) ?? 0.10
        currentFrame = try c.decodeIfPresent(Int.self, forKey: .currentFrame) ?? 0
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera) ?? Camera()
        showIsoSurface = try c.decodeIfPresent(Bool.self, forKey: .showIsoSurface) ?? true
        isoLevel = try c.decodeIfPresent(Float.self, forKey: .isoLevel) ?? 0
        isoSurfaces = try c.decodeIfPresent([IsoSurfaceSpec].self, forKey: .isoSurfaces) ?? []
        showFermiSurface = try c.decodeIfPresent(Bool.self, forKey: .showFermiSurface) ?? true
        bandStructure = try c.decodeIfPresent(BandStructure.self, forKey: .bandStructure) ?? nil
        densityOfStates = try c.decodeIfPresent(DensityOfStates.self, forKey: .densityOfStates) ?? nil
        multiOrbitalFields = try c.decodeIfPresent([ScalarField].self, forKey: .multiOrbitalFields) ?? []
        currentOrbital = try c.decodeIfPresent(Int.self, forKey: .currentOrbital) ?? 0
        grid2D = try c.decodeIfPresent(Grid2D.self, forKey: .grid2D) ?? nil
        forceSet = try c.decodeIfPresent(ForceSet.self, forKey: .forceSet) ?? nil
        showForces = try c.decodeIfPresent(Bool.self, forKey: .showForces) ?? false
        showColorPlane = (try c.decode(DefaultTrue.self, forKey: .showColorPlane)).wrappedValue
        bandSurface = try c.decodeIfPresent(BandSurface.self, forKey: .bandSurface) ?? nil
        showBandSurface = (try c.decode(DefaultTrue.self, forKey: .showBandSurface)).wrappedValue
        bandSurfaceOrientation = try c.decodeIfPresent(BandSurfaceOrientation.self, forKey: .bandSurfaceOrientation) ?? nil
        colorPlaneColormap = try c.decodeIfPresent(Colormap.self, forKey: .colorPlaneColormap) ?? .viridis
        colorPlaneContourEnabled = try c.decodeIfPresent(Bool.self, forKey: .colorPlaneContourEnabled) ?? true
        colorPlaneContourCount = try c.decodeIfPresent(Int.self, forKey: .colorPlaneContourCount) ?? 6
        volumeSlices = try c.decodeIfPresent([VolumeSlice].self, forKey: .volumeSlices) ?? []
        forceScale = try c.decodeIfPresent(Float.self, forKey: .forceScale) ?? 50.0
        msaaSampleCount = try c.decodeIfPresent(Int.self, forKey: .msaaSampleCount) ?? 1
        kPathPoints = try c.decodeIfPresent([KPoint].self, forKey: .kPathPoints) ?? []
        kPathBreaks = try c.decodeIfPresent(Set<Int>.self, forKey: .kPathBreaks) ?? []
        kPathProvenance = try c.decodeIfPresent(KPathProvenance.self, forKey: .kPathProvenance) ?? .generated
        kPathSignature = try c.decodeIfPresent(String.self, forKey: .kPathSignature) ?? nil
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1.0
        lineWidth = try c.decodeIfPresent(Float.self, forKey: .lineWidth) ?? 1.0
        depthCueingStrength = try c.decodeIfPresent(Float.self, forKey: .depthCueingStrength) ?? 0.0
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength) ?? 0.0
        shadowStrength = try c.decodeIfPresent(Float.self, forKey: .shadowStrength) ?? 0.0
        aoQuality = try c.decodeIfPresent(Int.self, forKey: .aoQuality) ?? 2
        shadowQuality = try c.decodeIfPresent(Int.self, forKey: .shadowQuality) ?? 2
        lights = try c.decodeIfPresent([SceneLightSource].self, forKey: .lights) ?? []
        hbondSettings = try c.decodeIfPresent(HbondSettings.self, forKey: .hbondSettings) ?? HbondSettings()
        hbondPairs = try c.decodeIfPresent([HbondPair].self, forKey: .hbondPairs) ?? []
        molecularSurfaceSettings = try c.decodeIfPresent(MolecularSurfaceSettings.self, forKey: .molecularSurfaceSettings) ?? MolecularSurfaceSettings()
        atomColorScheme = try c.decodeIfPresent(AtomColorScheme.self, forKey: .atomColorScheme) ?? .elemental
        elementOverrides = try c.decodeIfPresent([Int: ElementOverride].self, forKey: .elementOverrides) ?? [:]
        repetitionMode = try c.decodeIfPresent(RepetitionMode.self, forKey: .repetitionMode) ?? .unitCell
        cellRodsEnabled = try c.decodeIfPresent(Bool.self, forKey: .cellRodsEnabled) ?? false
        cellRodFactor = try c.decodeIfPresent(Float.self, forKey: .cellRodFactor) ?? 0.35
        unicolorBonds = try c.decodeIfPresent(Bool.self, forKey: .unicolorBonds) ?? false
        unicolorBondHex = try c.decodeIfPresent(String.self, forKey: .unicolorBondHex) ?? "#808080"
        tessellationFactor = try c.decodeIfPresent(Int.self, forKey: .tessellationFactor) ?? 0
    }

    // MARK: - Rendering quality controls
    // These drive configurable line widths, transparency, depth cueing, and
    // ambient-occlusion / soft-shadow approximations. All default to values that
    // preserve the original output exactly.

    /// Scene-object opacity (0 = fully transparent, 1 = fully opaque). At 1.0 the
    /// alpha-blended result is identical to the original opaque path.
    var opacity: Float = 1.0
    /// Line width in pixels for scene lines (cell frame, axes, BZ, k-path,
    /// measurements, forces). 1 = original 1px; >1 uses an expanded-quad path.
    var lineWidth: Float = 1.0
    /// Depth-cueing (fog) strength: 0 = off; >0 fades distant fragments toward
    /// the background color. The cueing range is derived from the framing sphere.
    var depthCueingStrength: Float = 0.0
    /// Ambient-occlusion strength: 0 = off; >0 darkens atoms/bonds surrounded by
    /// neighbors. The per-atom AO factor is computed from neighbor geometry.
    var aoStrength: Float = 0.0
    /// Soft-shadow strength: 0 = off; >0 darkens sides of atoms/bonds where
    /// neighbors block the light direction.
    var shadowStrength: Float = 0.0
    /// AO quality level (0 = off, 1 = low, 2 = medium, 3 = high). Controls the
    /// neighbor search radius and sampling density.
    var aoQuality: Int = 2
    /// Soft-shadow quality level (0 = off, 1 = low, 2 = medium, 3 = high).
    var shadowQuality: Int = 2
    /// Multi-light rig. Empty (default) = legacy single light — byte-identical
    /// output, upgraded scenes get up to 6 configurable sources.
    var lights: [SceneLightSource] = []
    /// H-bond detection/display settings. `hbondPairs` is populated by the
    /// controller when settings.enabled is set; the renderer only draws.
    var hbondSettings: HbondSettings = HbondSettings()
    var hbondPairs: [HbondPair] = []
    /// Molecular (solvent-accessible style) surface settings.
    var molecularSurfaceSettings: MolecularSurfaceSettings = MolecularSurfaceSettings()
    /// Active atom color scheme; `.elemental` reproduces today's output exactly.
    var atomColorScheme: AtomColorScheme = .elemental
    /// Per-element display overrides keyed by atomic number; defaults empty.
    var elementOverrides: [Int: ElementOverride] = [:]
    /// Unit-cell repetition display mode (unit cell vs asymmetric unit).
    var repetitionMode: RepetitionMode = .unitCell
    /// Crystal cell drawn as lit rods (XCrySDen "Crystal Cells As Rods") instead
    /// of unlit lines. Rod thickness = rodFactor * hydrogen covalent radius.
    var cellRodsEnabled: Bool = false
    var cellRodFactor: Float = 0.35
    /// Unicolor bonds: all bonds rendered in one color (O bonds currently inherit
    /// each atom's color). When enabled, `unicolorBondHex` wins over atom colors.
    var unicolorBonds: Bool = false
    var unicolorBondHex: String = "#808080"
    /// Geometry tessellation quality: 0 = legacy fixed counts (12/20 sphere,
    /// 12 cylinder) — byte-identical output; >0 scales sphere lat/lon and
    /// cylinder radial segments for smoother geometry.
    var tessellationFactor: Int = 0
}

// simd_quatf is not Codable in the Swift stdlib (only SIMD vectors are),
// but Camera (and therefore Scene) declares Codable. This conformance lets
// the declared codability hold without altering Camera's verbatim definition.
extension simd_quatf: @retroactive Codable {
    private enum CodingKeys: String, CodingKey { case x, y, z, w }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vector.x, forKey: .x)
        try c.encode(vector.y, forKey: .y)
        try c.encode(vector.z, forKey: .z)
        try c.encode(vector.w, forKey: .w)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = simd_float4(try c.decode(Float.self, forKey: .x),
                            try c.decode(Float.self, forKey: .y),
                            try c.decode(Float.self, forKey: .z),
                            try c.decode(Float.self, forKey: .w))
        self.init(vector: v)
    }
}

/// A Bool scene field that defaults to `true` when its key is absent from the
/// decoded JSON. Swift's synthesized Decodable throws `keyNotFound` for missing
/// keys rather than applying the struct's default value, so older serialized
/// Scene documents that predate the field would otherwise fail to decode. The
/// custom container overload below decodes the key when present and falls back
/// to `true` when absent; encoding writes the value normally.
@propertyWrapper
struct DefaultTrue: Codable {
    var wrappedValue: Bool

    init() { wrappedValue = true }
    init(wrappedValue: Bool = true) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = (try? c.decode(Bool.self)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: DefaultTrue.Type, forKey key: Key) throws -> DefaultTrue {
        try decodeIfPresent(Bool.self, forKey: key).map(DefaultTrue.init) ?? DefaultTrue()
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: DefaultTrue, forKey key: Key) throws {
        try encode(value.wrappedValue, forKey: key)
    }
}

/// A Bool scene field that defaults to `false` when its key is absent from the
/// decoded JSON. This keeps older serialized Scene documents decodable while
/// preserving the scale indicator's off-by-default behavior.
@propertyWrapper
struct DefaultFalse: Codable {
    var wrappedValue: Bool

    init() { wrappedValue = false }
    init(wrappedValue: Bool = false) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = (try? c.decode(Bool.self)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: DefaultFalse.Type, forKey key: Key) throws -> DefaultFalse {
        try decodeIfPresent(Bool.self, forKey: key).map(DefaultFalse.init) ?? DefaultFalse()
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: DefaultFalse, forKey key: Key) throws {
        try encode(value.wrappedValue, forKey: key)
    }
}
