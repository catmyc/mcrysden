import Foundation
import simd
import AppKit

struct Atom: Codable, Equatable { var coord: SIMD3<Float>; var atomicNumber: Int; var label: String
    /// Optional force on this atom (eV/Å), parsed from a QE `Forces acting on atoms`
    /// block when present. Drives the force-arrow overlay.
    var force: SIMD3<Float>?
}
struct Bond:  Codable { var i: Int; var j: Int }
struct Cell:  Codable { var a: SIMD3<Float>; var b: SIMD3<Float>; var c: SIMD3<Float> }

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

struct ColorScheme: Codable { var mode: String = "atomic" }

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
    var lighting: Lighting = Lighting()
    var showCellFrame: Bool = true
    var showAxes: Bool = true
    var showLabels: Bool = false
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
    /// Multiplier converting a force (eV/Å) to an arrow length (Å) so typical
    /// forces (0.01–1 eV/Å) span a few Å and read clearly. Sidebar-adjustable.
    var forceScale: Float = 50.0
    /// The user-edited reciprocal-space k-path: an ordered list of special
    /// k-points (fractional, conventional reciprocal basis) connecting BZ
    /// landmarks. Empty for non-crystal scenes; for crystals it defaults to the
    /// generated high-symmetry path (see Scene.init) until the user edits it.
    var kPathPoints: [KPoint] = []
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
