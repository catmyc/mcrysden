import Foundation
import simd

/// One merged powder-diffraction reflection. `hkl` is the canonical (smallest
/// 2θ) member of the d-merged set; `hklLabels` lists every member's "h k l".
struct XRDPeak: Equatable {
    let h: Int, k: Int, l: Int
    let hklLabels: [String]
    let dSpacing: Float
    let twoTheta: Float
    let intensity: Float
    let multiplicity: Int
    let relativeIntensity: Float
}

/// Gaussian-broadened powder-diffraction pattern: the merged peak list plus the
/// uniform 2θ profile, the curve maximum, a provenance tag, and (when the
/// computation cannot proceed) a failure reason.
struct XRDPattern: Equatable {
    let wavelength: Float
    let peaks: [XRDPeak]
    let curve: [(twoTheta: Float, intensity: Float)]
    let maxIntensity: Float
    let maxTwoTheta: Float
    let sourceDescription: String
    let unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }

    static func == (lhs: XRDPattern, rhs: XRDPattern) -> Bool {
        lhs.wavelength == rhs.wavelength &&
        lhs.peaks == rhs.peaks &&
        lhs.curve.count == rhs.curve.count &&
        lhs.maxIntensity == rhs.maxIntensity &&
        lhs.maxTwoTheta == rhs.maxTwoTheta &&
        lhs.sourceDescription == rhs.sourceDescription &&
        lhs.unavailableReason == rhs.unavailableReason &&
        lhs.curve.elementsEqual(rhs.curve) { $0.twoTheta == $1.twoTheta && $0.intensity == $1.intensity }
    }

    /// Serialize the merged peaks as CSV: "h,k,l,d (Å),2θ (°),I (raw),I (%),multiplicity".
    func peaksCSV() -> String {
        var lines = ["h,k,l,d (Å),2θ (°),I (raw),I (%),multiplicity"]
        for peak in peaks {
            lines.append("\(peak.h),\(peak.k),\(peak.l),\(peak.dSpacing),\(peak.twoTheta),\(peak.intensity),\(peak.relativeIntensity),\(peak.multiplicity)")
        }
        return lines.joined(separator: "\n")
    }

    /// Serialize the profile curve as CSV: "2θ (°),I".
    func curveCSV() -> String {
        var lines = ["2θ (°),I"]
        for point in curve {
            lines.append("\(point.twoTheta),\(point.intensity)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Powder X-ray diffraction computation engine.
///
/// Reflection enumeration, structure factors, multiplicity merging, and
/// Gaussian broadening follow the conventional (2π-in-reciprocal) physics
/// contract pinned by the API. All work is bounded and fails closed: any
/// invalid input yields an `XRDPattern` whose `unavailableReason` names the
/// cause rather than trapping or returning a partial result.
///
/// Form factors use the Waasmaier–Kirfel 5-Gaussian fit
/// (D. Waasmaier & A. Kirfel, Acta Cryst. A51, 416-413, 1995), the canonical
/// Cromer–Mann-style parameterization distributed via the DABAX/ESRF library
/// and embedded by CCTBX, GSAS-II, and periodictable. Published neutral-atom
/// coefficients exist for Z = 1…98; Z = 99…118 (no published analytic fit) use
/// the Cf (Z=98) shape renormalized so f(0) = Z.
enum PowderXRD {

    /// Cu Kα₁ in Å — the conventional laboratory wavelength.
    static let defaultWavelength: Float = 1.540598

    /// Common laboratory X-ray source options: (name, wavelength in Å).
    static let wavelengthOptions: [(name: String, wavelength: Float)] = [
        ("Cu Kα₁", 1.540598), ("Cu Kα", 1.54184), ("Mo Kα", 0.70930),
        ("Cr Kα", 2.28970), ("Fe Kα", 1.93604), ("Co Kα", 1.78897),
        ("Mn Kα", 2.10314), ("Ag Kα", 0.55941),
    ]

    /// (c, [a1…a5], [b1…b5]) Waasmaier–Kirfel coefficients, indexed by Z-1.
    /// Z=1…98: published neutral-atom coefficients from the Waasmaier–Kirfel 1995
    /// table (f0_WaasKirf.dat, python-periodictable/DABAX/ESRF). Z=99…118:
    /// Cf shape renormalized to f(0)=Z (no published analytic fit exists).
    private static let cromerMann: [(c: Float, a: [Float], b: [Float])] = [
        /*   1 */ (0.000049, [0.413048, 0.294953, 0.187491, 0.080701, 0.023736], [15.569946, 32.398468, 5.711404, 61.889874, 1.334118]),
        /*   2 */ (0.000487, [0.732354, 0.753896, 0.283819, 0.190003, 0.039139], [11.553918, 4.595831, 1.546299, 26.463964, 0.377523]),
        /*   3 */ (0.002542, [0.974637, 0.158472, 0.811855, 0.262416, 0.790108], [4.334946, 0.342451, 97.102966, 201.363831, 1.409234]),
        /*   4 */ (0.002511, [1.533712, 0.638283, 0.601052, 0.106139, 1.118414], [42.662079, 0.595420, 99.106499, 0.151340, 1.843093]),
        /*   5 */ (0.003823, [2.085185, 1.064580, 1.062788, 0.140515, 0.641784], [23.494068, 1.137894, 61.238976, 0.114886, 0.399036]),
        /*   6 */ (4.297983, [2.657506, 1.078079, 1.490909, -4.241070, 0.713791], [14.780758, 0.776775, 42.086842, -0.000294, 0.239535]),
        /*   7 */ (-11.804902, [11.893780, 3.277479, 1.858092, 0.858927, 0.912985], [0.000158, 10.232723, 30.344690, 0.656065, 0.217287]),
        /*   8 */ (0.027014, [2.960427, 2.508818, 0.637853, 0.722838, 1.142756], [14.182259, 5.936858, 0.112726, 34.958481, 0.390240]),
        /*   9 */ (0.032557, [3.511943, 2.772244, 0.678385, 0.915159, 1.089261], [10.687859, 4.380466, 0.093982, 27.255203, 0.313066]),
        /*  10 */ (0.025576, [4.183749, 2.905726, 0.520513, 1.135641, 1.228065], [8.175457, 3.252536, 0.063295, 21.813910, 0.224952]),
        /*  11 */ (0.079712, [4.910127, 3.081783, 1.262067, 1.098938, 0.560991], [3.281434, 9.119178, 0.102763, 132.013947, 0.405878]),
        /*  12 */ (0.126842, [4.708971, 1.194814, 1.558157, 1.170413, 3.239403], [4.875207, 108.506081, 0.111516, 48.292408, 1.928171]),
        /*  13 */ (0.139509, [4.730796, 2.313951, 1.541980, 1.117564, 3.154754], [3.628931, 43.051167, 0.095960, 108.932388, 1.555918]),
        /*  14 */ (0.145073, [5.275329, 3.191038, 1.511514, 1.356849, 2.519114], [2.631338, 33.730728, 0.081119, 86.288643, 1.170087]),
        /*  15 */ (0.155233, [1.950541, 4.146930, 1.494560, 1.522042, 5.729711], [0.908139, 27.044952, 0.071280, 67.520187, 1.981173]),
        /*  16 */ (0.154722, [6.372157, 5.154568, 1.473732, 1.635073, 1.209372], [1.514347, 22.092527, 0.061373, 55.445175, 0.646925]),
        /*  17 */ (0.146773, [1.446071, 6.870609, 6.151801, 1.750347, 0.634168], [0.052357, 1.193165, 18.343416, 46.398396, 0.401005]),
        /*  18 */ (0.265954, [7.188004, 6.638454, 0.454180, 1.929593, 1.523654], [0.956221, 15.339877, 15.339862, 39.043823, 0.062409]),
        /*  19 */ (0.253614, [8.163991, 7.146945, 1.070140, 0.877316, 1.486434], [12.816323, 0.808945, 210.327011, 39.597652, 0.052821]),
        /*  20 */ (0.196255, [8.593655, 1.477324, 1.436254, 1.182839, 7.113258], [10.460644, 0.041891, 81.390381, 169.847839, 0.688098]),
        /*  21 */ (0.157765, [1.476566, 1.487278, 1.600187, 9.177463, 7.099750], [53.131023, 0.035325, 137.319489, 9.098031, 0.602102]),
        /*  22 */ (0.102473, [9.818524, 1.522646, 1.703101, 1.768774, 7.082555], [8.001879, 0.029763, 39.885422, 120.157997, 0.532405]),
        /*  23 */ (0.067744, [10.473575, 1.547881, 1.986381, 1.865616, 7.056250], [7.081940, 0.026040, 31.909672, 108.022842, 0.474882]),
        /*  24 */ (0.065510, [11.007069, 1.555477, 2.985293, 1.347855, 7.034779], [6.366281, 0.023987, 23.244839, 105.774498, 0.429369]),
        /*  25 */ (-0.147293, [11.709542, 1.733414, 2.673141, 2.023368, 7.003180], [5.597120, 0.017800, 21.788420, 89.517914, 0.383054]),
        /*  26 */ (-0.304931, [12.311098, 1.876623, 3.066177, 2.070451, 6.975185], [5.009415, 0.014461, 18.743040, 82.767876, 0.346506]),
        /*  27 */ (-0.936572, [12.914510, 2.481908, 3.466894, 2.106351, 6.960892], [4.507138, 0.009126, 16.438129, 76.987320, 0.314418]),
        /*  28 */ (-2.762697, [13.521865, 6.947285, 3.866028, 2.135900, 4.284731], [4.077277, 0.286763, 14.622634, 71.966080, 0.004437]),
        /*  29 */ (-3.254477, [14.014192, 4.784577, 5.056806, 1.457971, 6.932996], [3.738280, 0.003744, 13.034982, 72.554794, 0.265666]),
        /*  30 */ (-36.915829, [14.741002, 6.907748, 4.642337, 2.191766, 38.424042], [3.388232, 0.243315, 11.903689, 63.312130, 0.000397]),
        /*  31 */ (-0.847395, [15.758946, 6.841123, 4.121016, 2.714681, 2.395246], [3.121754, 0.226057, 12.482196, 66.203621, 0.007238]),
        /*  32 */ (0.018726, [16.540613, 1.567900, 3.727829, 3.345098, 6.785079], [2.866618, 0.012198, 13.432163, 58.866047, 0.210974]),
        /*  33 */ (-2.984117, [17.025642, 4.503441, 3.715904, 3.937200, 6.790175], [2.597739, 0.003012, 14.272119, 50.437996, 0.193015]),
        /*  34 */ (-3.160982, [17.354071, 4.653248, 4.259489, 4.136455, 6.749163], [2.349787, 0.002550, 15.579460, 45.181202, 0.177432]),
        /*  35 */ (-2.492088, [17.550570, 5.411882, 3.937180, 3.880645, 6.707793], [2.119226, 16.557184, 0.002481, 42.164009, 0.162121]),
        /*  36 */ (-2.810592, [17.655279, 6.848105, 4.171004, 3.446760, 6.685200], [1.908231, 16.606236, 0.001598, 39.917473, 0.146896]),
        /*  37 */ (1.139548, [8.123134, 2.138042, 6.761702, 1.156051, 17.679546], [15.142385, 33.542667, 0.129372, 224.132507, 1.713368]),
        /*  38 */ (1.140251, [17.730219, 9.795867, 6.099763, 2.620025, 0.600053], [1.563060, 14.310868, 0.120574, 135.771317, 0.120574]),
        /*  39 */ (1.131787, [17.792040, 10.253252, 5.714949, 3.170516, 0.918251], [1.429691, 13.132816, 0.112173, 108.197029, 0.112173]),
        /*  40 */ (1.124859, [17.859772, 10.911038, 5.821115, 3.512513, 0.746965], [1.310692, 12.319285, 0.104353, 91.777542, 0.104353]),
        /*  41 */ (1.123452, [17.958399, 12.063054, 5.007015, 3.287667, 1.531019], [1.211590, 12.246687, 0.098615, 75.011948, 0.098615]),
        /*  42 */ (1.108770, [6.236218, 17.987711, 12.973127, 3.451426, 0.210899], [0.090780, 1.108310, 11.468720, 66.684151, 0.090780]),
        /*  43 */ (1.074784, [17.840963, 3.428236, 1.373012, 12.947364, 6.335469], [1.005729, 41.901382, 119.320541, 9.781542, 0.083391]),
        /*  44 */ (1.043992, [6.271624, 17.906738, 14.123269, 3.746008, 0.908235], [0.077040, 0.928222, 9.555345, 35.860680, 123.552246]),
        /*  45 */ (0.995452, [6.216648, 17.919739, 3.854252, 0.840326, 15.173498], [0.070789, 0.856121, 33.889484, 121.686691, 9.029517]),
        /*  46 */ (0.883099, [6.121511, 4.784063, 16.631683, 4.318258, 13.246773], [0.062549, 0.784031, 8.751391, 34.489983, 0.784031]),
        /*  47 */ (0.756603, [6.073874, 17.155437, 4.173344, 0.852238, 17.988686], [0.055333, 7.896512, 28.443739, 110.376106, 0.716809]),
        /*  48 */ (0.603504, [6.080986, 18.019468, 4.018197, 1.303510, 17.974669], [0.048990, 7.273646, 29.119284, 95.831207, 0.661231]),
        /*  49 */ (0.333097, [6.196477, 18.816183, 4.050479, 1.638929, 17.962912], [0.042072, 6.695665, 31.009790, 103.284348, 0.610714]),
        /*  50 */ (0.119024, [19.325171, 6.281571, 4.498866, 1.856934, 17.917318], [6.118104, 0.036915, 32.529045, 95.037186, 0.565651]),
        /*  51 */ (-0.290506, [5.394956, 6.549570, 19.650681, 1.827820, 17.867832], [33.326523, 0.030974, 5.564929, 87.130966, 0.523992]),
        /*  52 */ (-0.806668, [6.660302, 6.940756, 19.847015, 1.557175, 17.802427], [33.031654, 0.025750, 5.065547, 84.101616, 0.487660]),
        /*  53 */ (-0.448811, [19.884502, 6.736593, 8.110516, 1.170953, 17.548716], [4.628591, 0.027754, 31.849096, 84.406387, 0.463550]),
        /*  54 */ (-6.065902, [19.978920, 11.774945, 9.332182, 1.244749, 17.737501], [4.143356, 0.010142, 28.796200, 75.280685, 0.413616]),
        /*  55 */ (-2.322802, [17.418674, 8.314444, 10.323193, 1.383834, 19.876251], [0.399828, 0.016872, 25.605827, 233.339676, 3.826915]),
        /*  56 */ (-5.183497, [19.747343, 17.368477, 10.465718, 2.592602, 11.003653], [3.481823, 0.371224, 21.226641, 173.834274, 0.010719]),
        /*  57 */ (-21.745489, [19.966019, 27.329655, 11.018425, 3.086696, 17.335455], [3.197408, 0.003446, 19.955492, 141.381973, 0.341817]),
        /*  58 */ (-38.386017, [17.355122, 43.988499, 20.546650, 3.130670, 11.353665], [0.328369, 0.002047, 3.088196, 134.907654, 18.832960]),
        /*  59 */ (-3.871068, [21.551311, 17.161730, 11.903859, 2.679103, 9.564197], [2.995675, 0.312491, 17.716705, 152.192825, 0.010468]),
        /*  60 */ (-57.189842, [17.331244, 62.783924, 12.160097, 2.663483, 22.239950], [0.300269, 0.001320, 17.026001, 148.748993, 2.910268]),
        /*  61 */ (-45.973682, [17.286388, 51.560162, 12.478557, 2.675515, 22.960947], [0.286620, 0.001550, 16.223755, 143.984512, 2.796480]),
        /*  62 */ (-17.452166, [23.700363, 23.072214, 12.777782, 2.684217, 17.204367], [2.689539, 0.003491, 15.495437, 139.862473, 0.274536]),
        /*  63 */ (-31.586687, [17.186195, 37.156837, 13.103387, 2.707246, 24.419271], [0.261678, 0.001995, 14.787360, 134.816299, 2.581883]),
        /*  64 */ (-43.505684, [24.898117, 17.104952, 13.222581, 3.266152, 48.995213], [2.435028, 0.246961, 13.996325, 110.863091, 0.001383]),
        /*  65 */ (-26.851971, [25.910013, 32.344139, 13.765117, 2.751404, 17.064405], [2.373912, 0.002034, 13.481969, 125.836510, 0.236916]),
        /*  66 */ (-83.279831, [26.671785, 88.687576, 14.065445, 2.768497, 17.067781], [2.282593, 0.000665, 12.920230, 121.937187, 0.225531]),
        /*  67 */ (-41.165253, [27.150190, 16.999819, 14.059334, 3.386979, 46.546471], [2.169660, 0.215414, 12.213148, 100.506783, 0.001211]),
        /*  68 */ (-77.135223, [28.174887, 82.493271, 14.624002, 2.802756, 17.018515], [2.120995, 0.000640, 11.915256, 114.529938, 0.207519]),
        /*  69 */ (-70.839813, [28.925894, 76.173798, 14.904704, 2.814812, 16.998117], [2.046203, 0.000656, 11.465375, 111.411980, 0.199376]),
        /*  70 */ (-60.313812, [29.676760, 65.624069, 15.160854, 2.830288, 16.997850], [1.977630, 0.000720, 11.044622, 108.139153, 0.192110]),
        /*  71 */ (-51.049416, [30.122866, 15.099346, 56.314899, 3.540980, 16.943729], [1.883090, 10.342764, 0.000780, 89.559250, 0.183849]),
        /*  72 */ (-49.719837, [30.617033, 15.145351, 54.933548, 4.096253, 16.896156], [1.795613, 9.934469, 0.000739, 76.189705, 0.175914]),
        /*  73 */ (-44.119026, [31.066359, 15.341823, 49.278297, 4.577665, 16.828321], [1.708732, 9.618455, 0.000760, 66.346199, 0.168002]),
        /*  74 */ (-32.864574, [31.507900, 15.682498, 37.960129, 4.885509, 16.792112], [1.629485, 9.446448, 0.000898, 59.980675, 0.160798]),
        /*  75 */ (-37.412682, [31.888456, 16.117104, 42.390297, 5.211669, 16.767591], [1.549238, 9.233474, 0.000689, 54.516373, 0.152815]),
        /*  76 */ (-43.677956, [32.210297, 16.678440, 48.559906, 5.455839, 16.735533], [1.473531, 9.049695, 0.000519, 50.210201, 0.145771]),
        /*  77 */ (4.018893, [32.004436, 1.975454, 17.070105, 15.939454, 5.990003], [1.353767, 81.014175, 0.128093, 7.661196, 26.659403]),
        /*  78 */ (4.050394, [31.273891, 18.445440, 17.063745, 5.555933, 1.575270], [1.316992, 8.797154, 0.124741, 40.177994, 1.316997]),
        /*  79 */ (-6.279078, [16.777390, 19.317156, 32.979683, 5.595453, 10.576854], [0.122737, 8.621570, 1.256902, 38.008820, 0.000601]),
        /*  80 */ (4.076478, [16.839890, 20.023823, 28.428564, 5.881564, 4.714706], [0.115905, 8.256927, 1.195250, 39.247227, 1.195250]),
        /*  81 */ (4.066939, [16.630795, 19.386616, 32.808571, 1.747191, 6.356862], [0.110704, 7.181401, 1.119730, 90.660263, 26.014978]),
        /*  82 */ (4.049824, [16.419567, 32.738590, 6.530247, 2.342742, 19.916475], [0.105499, 1.055049, 25.025890, 80.906593, 6.664449]),
        /*  83 */ (4.040914, [16.282274, 32.725136, 6.678302, 2.694750, 20.576559], [0.101180, 1.002287, 25.714146, 77.057549, 6.291882]),
        /*  84 */ (4.046556, [16.289164, 32.807171, 21.095163, 2.505901, 7.254589], [0.098121, 0.966265, 6.046622, 76.598068, 28.096128]),
        /*  85 */ (3.995684, [16.011461, 32.615547, 8.113899, 2.884082, 21.377867], [0.092639, 0.904416, 26.543257, 68.372963, 5.499512]),
        /*  86 */ (4.020977, [16.070229, 32.641106, 21.489658, 2.299218, 9.480184], [0.090437, 0.876409, 5.239687, 69.188477, 27.632641]),
        /*  87 */ (4.003472, [16.007385, 32.663830, 21.594351, 1.598497, 11.121192], [0.087031, 0.840187, 4.954467, 199.805801, 26.905106]),
        /*  88 */ (3.981773, [32.563690, 21.396671, 11.298093, 2.834688, 15.914965], [0.801980, 4.590666, 22.758972, 160.404388, 0.083544]),
        /*  89 */ (3.939212, [15.914053, 32.535042, 21.553976, 11.433394, 3.612409], [0.080511, 0.770669, 4.352206, 21.381622, 130.500748]),
        /*  90 */ (3.922533, [15.784024, 32.454899, 21.849222, 4.239077, 11.736191], [0.077067, 0.735137, 4.097976, 109.464111, 20.512138]),
        /*  91 */ (3.886066, [32.740208, 21.973675, 12.957398, 3.683832, 15.744058], [0.709545, 4.050881, 19.231543, 117.255005, 0.074040]),
        /*  92 */ (3.854444, [15.679275, 32.824306, 13.660459, 3.687261, 22.279434], [0.071206, 0.681177, 18.236156, 112.500038, 3.930325]),
        /*  93 */ (3.769391, [32.999901, 22.638077, 14.219973, 3.672950, 15.683245], [0.657086, 3.854918, 17.435474, 109.464485, 0.068033]),
        /*  94 */ (3.664200, [33.281178, 23.148544, 15.153755, 3.031492, 15.704215], [0.634999, 3.856168, 16.849735, 121.292038, 0.064857]),
        /*  95 */ (3.541160, [33.435162, 23.657259, 15.576339, 3.027023, 15.746100], [0.612785, 3.792942, 16.195778, 117.757004, 0.061755]),
        /*  96 */ (3.390840, [15.804837, 33.480801, 24.150198, 3.655563, 15.499866], [0.058619, 0.590160, 3.674720, 100.736191, 15.408296]),
        /*  97 */ (3.213169, [15.889072, 33.625286, 24.710381, 3.707139, 15.839268], [0.055503, 0.569571, 3.615472, 97.694786, 14.754303]),
        /*  98 */ (3.005326, [33.794075, 25.467693, 16.048487, 3.657525, 16.008982], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /*  99 */ (3.036548, [34.145153, 25.732271, 16.215211, 3.695522, 16.175295], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 100 */ (3.067220, [34.490054, 25.992193, 16.379001, 3.732851, 16.338682], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 101 */ (3.097892, [34.834954, 26.252114, 16.542791, 3.770179, 16.502069], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 102 */ (3.128564, [35.179855, 26.512036, 16.706581, 3.807508, 16.665456], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 103 */ (3.159236, [35.524756, 26.771958, 16.870371, 3.844836, 16.828843], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 104 */ (3.189909, [35.869656, 27.031880, 17.034161, 3.882165, 16.992230], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 105 */ (3.220581, [36.214557, 27.291802, 17.197951, 3.919493, 17.155616], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 106 */ (3.251253, [36.559457, 27.551724, 17.361741, 3.956822, 17.319003], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 107 */ (3.281925, [36.904358, 27.811646, 17.525531, 3.994150, 17.482390], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 108 */ (3.312597, [37.249258, 28.071568, 17.689321, 4.031479, 17.645777], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 109 */ (3.343270, [37.594159, 28.331490, 17.853111, 4.068807, 17.809164], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 110 */ (3.373942, [37.939059, 28.591412, 18.016901, 4.106136, 17.972550], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 111 */ (3.404614, [38.283960, 28.851334, 18.180691, 4.143464, 18.135937], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 112 */ (3.435286, [38.628860, 29.111256, 18.344481, 4.180793, 18.299324], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 113 */ (3.465958, [38.973761, 29.371178, 18.508271, 4.218121, 18.462711], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 114 */ (3.496631, [39.318661, 29.631100, 18.672061, 4.255450, 18.626098], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 115 */ (3.527303, [39.663562, 29.891021, 18.835851, 4.292778, 18.789485], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 116 */ (3.557975, [40.008463, 30.150943, 18.999641, 4.330107, 18.952871], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 117 */ (3.588647, [40.353363, 30.410865, 19.163431, 4.367435, 19.116258], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
        /* 118 */ (3.619319, [40.698264, 30.670787, 19.327221, 4.404764, 19.279645], [0.550447, 3.581973, 14.357388, 96.064972, 0.052450]),
    ]

    /// Waasmaier–Kirfel 5-Gaussian scattering factor f(s) = c + Σ aᵢ·exp(-bᵢ·s²),
    /// with s = sinθ/λ in Å⁻¹. Valid neutral-atom data exist for Z = 1…98
    /// (Waasmaier & Kirfel, Acta Cryst. A51, 416-413, 1995); Z = 99…118 use the
    /// Cf (Z=98) shape renormalized to f(0) = Z. Coefficients with a negative
    /// b diverge at extreme s, so the input is clamped to 6 Å⁻¹ (beyond any
    /// observable scattering angle).
    static func scatteringFactor(Z: Int, s: Float) -> Float {
        guard Z >= 1, Z <= cromerMann.count else { return 0 }
        let coeff = cromerMann[Z - 1]
        let s2 = min(s, 6) * min(s, 6)
        var f = coeff.c
        for i in 0..<5 {
            f += coeff.a[i] * exp(-coeff.b[i] * s2)
        }
        return f
    }

    // MARK: - Crystal-system / Laue-class multiplicity fallback

    /// Crystal system inferred from the cell metric (a,b,c lengths and angles).
    private enum CrystalSystem { case cubic, hexagonal, trigonal, tetragonal, orthorhombic, monoclinic, triclinic }

    private static func crystalSystem(cell: Cell) -> CrystalSystem {
        let la = Double(simd_length(cell.a)), lb = Double(simd_length(cell.b)), lc = Double(simd_length(cell.c))
        func ang(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Double {
            let lu = Double(simd_length(u)), lv = Double(simd_length(v)); guard lu>1e-12, lv>1e-12 else { return 90 }
            return acos(max(-1,min(1,Double(simd_dot(u,v))/(lu*lv))))*180/Double.pi
        }
        let alpha = ang(cell.b, cell.c)
        let beta = ang(cell.a, cell.c)
        let gamma = ang(cell.a, cell.b)
        let eq = { (x: Double, y: Double) in abs(x - y) < 1e-3 }
        let right = { (x: Double) in abs(x - 90) < 1e-3 }
        if eq(la, lb) && eq(lb, lc) && right(alpha) && right(beta) && right(gamma) { return .cubic }
        if right(alpha) && right(beta) && eq(gamma, 120) { return .hexagonal }
        if eq(la, lb) && right(alpha) && right(beta) && right(gamma) { return .tetragonal }
        if eq(la, lb) && eq(lb, lc) && right(alpha) == false && right(beta) == false && right(gamma) == false {
            return .trigonal
        }
        if right(alpha) && right(beta) && right(gamma) { return .orthorhombic }
        if right(alpha) && right(gamma) { return .monoclinic }
        return .triclinic
    }

    /// Canonical Laue-class orbit size for the crystal system. Special positions
    /// (zero components, equal components) reduce the count. This is only exact
    /// when `cell` is a conventional cell in standard setting. A rhombohedral
    /// crystal described in a hexagonal setting falls under the hexagonal Laue
    /// class here (exact multiplicities in that case require `symmetryOps`).
    private static func laueMultiplicity(system: CrystalSystem, h: Int, k: Int, l: Int) -> Int {
        switch system {
        case .cubic:
            let arr = [abs(h), abs(k), abs(l)].sorted()
            if arr[0] == 0 && arr[1] == 0 {
                return 6                       // (h00)
            } else if arr[0] == 0 {
                return arr[1] == arr[2] ? 12 : 24   // (0hh) vs (0hk)
            } else {
                if arr[0] == arr[1] && arr[1] == arr[2] { return 8 }   // (hhh)
                return arr[0] == arr[1] || arr[1] == arr[2] ? 24 : 48 // (hhk) vs (hkl)
            }
        case .hexagonal:
            // Point group 6/mmm (Laue 6/mmm), order 24 generic. Special
            // positions reduce by the site symmetry: (00l) has 6-fold axial
            // symmetry; (hk0) with h=0/k=0/h=k sits on mirrors.
            if h == 0 && k == 0 { return 2 }                 // (00l)
            if l == 0 && (h == 0 || k == 0 || h == k) { return 6 }  // (hk0) special
            if l == 0 { return 12 }                           // (hk0) generic
            if h == 0 || k == 0 || h == k { return 12 }       // (hkl) with mirror
            return 24                                         // (hkl) generic
        case .trigonal: return 12
        case .tetragonal: return 16
        case .orthorhombic: return 8
        case .monoclinic: return 4
        case .triclinic: return 2
        }
    }

    // MARK: - Entry point

    /// Compute the powder XRD pattern for the given structure.
    ///
    /// Parameters are clamped to documented safe ranges (non-finite inputs fail
    /// closed). `symmetryOps`, when provided, drives exact orbit-counted
    /// multiplicity; otherwise a Laue-class estimate is used. `electronDensity`,
    /// when present, overrides the atomic form-factor route with a separable DFT
    /// projection of the grid.
    static func analyze(cell: Cell?, atoms: [Atom], periodicDim: Int,
                        wavelength: Float = defaultWavelength,
                        maxTwoTheta: Float = 120,
                        hklLimit: Int = 8,
                        fwhm: Float = 0.5,
                        curveStep: Float = 0.05,
                        symmetryOps: [CrystalSymmetryOperation]? = nil,
                        electronDensity: ScalarField? = nil) -> XRDPattern {

        // Non-finite parameters fail closed before any arithmetic (NaN would
        // otherwise trap in ceil/clamp or silently produce an empty pattern).
        // hklLimit is an Int (always finite); the Float parameters are checked
        // directly. The hklLimit conversion guards against a Float-coded call site.
        if !wavelength.isFinite || !maxTwoTheta.isFinite || !Float(hklLimit).isFinite
            || !fwhm.isFinite || !curveStep.isFinite {
            return .unavailable(wavelength: wavelength, reason: "non-finite parameter")
        }

        // Wavelength is clamped into the documented 0.2...4 Å range (only
        // non-finite wavelengths fail; finite out-of-range values are clamped).
        var wave = max(0.2, min(4, wavelength))
        let max2T = max(5, min(160, maxTwoTheta))
        let L = max(1, min(12, hklLimit))
        let sigma = fwhm / (2 * sqrt(2 * log(2)))
        var step = max(0.01, min(1, curveStep))
        var nSamples = Int(ceil(Double(max2T) / Double(step)))
        if nSamples > 8000 {
            nSamples = 8000
            step = max2T / Float(nSamples)
        }
        let curveSamples = max(2, nSamples + 1)

        // Validation.
        if periodicDim != 3 { return .unavailable(wavelength: wavelength, reason: "requires a 3D periodic crystal") }
        guard let cell = cell else { return .unavailable(wavelength: wavelength, reason: "no unit cell") }
        if atoms.isEmpty { return .unavailable(wavelength: wavelength, reason: "no base atoms") }
        let comps = [cell.a.x, cell.a.y, cell.a.z, cell.b.x, cell.b.y, cell.b.z, cell.c.x, cell.c.y, cell.c.z]
        if !comps.allSatisfy({ $0.isFinite }) { return .unavailable(wavelength: wavelength, reason: "unit cell is singular or non-finite") }
        guard cell.inverseMatrix != nil else { return .unavailable(wavelength: wavelength, reason: "unit cell is singular") }
        for (i, atom) in atoms.enumerated() {
            if !atom.coord.x.isFinite || !atom.coord.y.isFinite || !atom.coord.z.isFinite {
                return .unavailable(wavelength: wavelength, reason: "non-finite atom coordinate at index \(i)")
            }
        }
        for (i, atom) in atoms.enumerated() {
            let z = atom.atomicNumber
            if z < 1 || z > 118 { return .unavailable(wavelength: wavelength, reason: "invalid atomic number at index \(i)") }
        }

        // Fractional coordinates (wrapped to [0,1)).
        let inv = cell.inverseMatrix!
        let sourceDesc = "atomic form factors"
        let fracCoords = atoms.map { atom -> SIMD3<Double> in
            let f = inv * SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            return SIMD3<Double>(f.x - floor(f.x), f.y - floor(f.y), f.z - floor(f.z))
        }

        // Electron-density projection path.
        if let grid = electronDensity {
            if let reason = validateElectronDensity(grid, cell: cell) {
                return .unavailable(wavelength: wavelength, reason: reason)
            }
            let perm = electronDensityPermutation(grid, cell: cell)
            return electronDensityPattern(cell: cell, grid: grid, inv: inv,
                                          wavelength: wave, max2T: max2T, L: L, sigma: sigma,
                                          step: step, curveSamples: curveSamples,
                                          symmetryOps: symmetryOps, perm: perm)
        }

        return atomicFormFactorPattern(cell: cell, atoms: atoms, fracCoords: fracCoords,
                                       wavelength: wave, max2T: max2T, L: L, sigma: sigma,
                                       step: step, curveSamples: curveSamples,
                                       symmetryOps: symmetryOps, sourceDesc: sourceDesc)
    }

    // MARK: - Validation helpers

    private static func validateElectronDensity(_ grid: ScalarField, cell: Cell) -> String? {
        guard grid.nx >= 2, grid.ny >= 2, grid.nz >= 2 else { return "electron-density grid too small" }
        guard grid.nx <= 128, grid.ny <= 128, grid.nz <= 128 else { return "electron-density grid too large for projection" }
        let total = grid.nx * grid.ny * grid.nz
        guard total >= 0, total <= (1 << 21) else { return "electron-density grid too large for projection" }
        guard grid.vec.count >= 3 else { return "electron-density grid not aligned with the unit cell" }
        // Signed-permutation bijection test.
        let gridAxes = [SIMD3<Double>(Double(grid.vec[0].x), Double(grid.vec[0].y), Double(grid.vec[0].z)),
                        SIMD3<Double>(Double(grid.vec[1].x), Double(grid.vec[1].y), Double(grid.vec[1].z)),
                        SIMD3<Double>(Double(grid.vec[2].x), Double(grid.vec[2].y), Double(grid.vec[2].z))]
        let cellAxes = [SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z)),
                        SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z)),
                        SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))]
        var used = [false, false, false]
        var signs = [1, 1, 1]
        for ga in gridAxes {
            var best = -1
            var bestDot: Double = 0
            for (j, ca) in cellAxes.enumerated() {
                if used[j] { continue }
                let caLen = simd_length(ca)
                guard caLen > 1e-9 else { continue }
                let d = abs(simd_dot(ga, ca)) / (simd_length(ga) * caLen)
                if d > bestDot { bestDot = d; best = j }
            }
            guard best >= 0 else { return "electron-density grid not aligned with the unit cell" }
            let caLen = simd_length(cellAxes[best])
            let gaLen = simd_length(ga)
            let lengthOk = abs(gaLen - caLen) <= 0.02 * caLen
            let angleOk = bestDot >= cos(2 * .pi / 180)
            if !lengthOk || !angleOk { return "electron-density grid not aligned with the unit cell" }
            signs[best] = simd_dot(ga, cellAxes[best]) < 0 ? -1 : 1
            used[best] = true
        }
        if !used.allSatisfy({ $0 }) { return "electron-density grid not aligned with the unit cell" }
        return nil
    }

    /// Signed permutation: for each grid axis i, which cell axis it maps to, and the sign.
    private static func electronDensityPermutation(_ grid: ScalarField, cell: Cell) -> [(Int, Int)] {
        let gridAxes = [SIMD3<Double>(Double(grid.vec[0].x), Double(grid.vec[0].y), Double(grid.vec[0].z)),
                        SIMD3<Double>(Double(grid.vec[1].x), Double(grid.vec[1].y), Double(grid.vec[1].z)),
                        SIMD3<Double>(Double(grid.vec[2].x), Double(grid.vec[2].y), Double(grid.vec[2].z))]
        let cellAxes = [SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z)),
                        SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z)),
                        SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))]
        var result: [(Int, Int)] = []
        for ga in gridAxes {
            var best = 0
            var bestDot: Double = 0
            for (j, ca) in cellAxes.enumerated() {
                let caLen = simd_length(ca)
                guard caLen > 1e-9 else { continue }
                let d = abs(simd_dot(ga, ca)) / (simd_length(ga) * caLen)
                if d > bestDot { bestDot = d; best = j }
            }
            let s = simd_dot(ga, cellAxes[best]) < 0 ? -1 : 1
            result.append((best, s))
        }
        return result
    }

    // MARK: - Multiplicity

    /// Canonical signed representative: the permutation of (h,k,l) whose first
    /// nonzero component is positive (used for hklLabels).
    private static func makeCanonical(_ h: Int, _ k: Int, _ l: Int) -> (Int, Int, Int) {
        if h > 0 || (h == 0 && k > 0) || (h == 0 && k == 0 && l > 0) {
            return (h, k, l)
        }
        return (-h, -k, -l)
    }

    /// Explicit orbit-count under the rotation parts of the symmetry ops.
    /// Each sign-canonicalized orbit member is multiplied by 2: a powder Debye
    /// ring receives contributions from BOTH (h,k,l) and (−h,−k,−l) (Friedel
    /// partners, equal |F|), so the multiplicity counts both signs. This is
    /// exact whether or not −I is in the op set — if it is, both partners are
    /// already generated and the canonical dedup merges them; if not, the
    /// missing partner still diffracts into the same ring and must be counted.
    private static func explicitMultiplicity(h: Int, k: Int, l: Int,
                                              ops: [CrystalSymmetryOperation]) -> Int {
        var seen: Set<SIMD3<Int>> = []
        for op in ops {
            guard op.rotation.count == 9 else { continue }
            let r = op.rotation
            let hh = r[0] * h + r[1] * k + r[2] * l
            let kk = r[3] * h + r[4] * k + r[5] * l
            let ll = r[6] * h + r[7] * k + r[8] * l
            let c = makeCanonical(hh, kk, ll)
            seen.insert(SIMD3<Int>(c.0, c.1, c.2))
        }
        return seen.isEmpty ? 1 : seen.count * 2
    }

    private static func multiplicity(h: Int, k: Int, l: Int,
                                      symmetryOps: [CrystalSymmetryOperation]?,
                                      cell: Cell) -> Int {
        if let ops = symmetryOps, !ops.isEmpty {
            let m = explicitMultiplicity(h: h, k: k, l: l, ops: ops)
            return m
        }
        return laueMultiplicity(system: crystalSystem(cell: cell), h: h, k: k, l: l)
    }

    // MARK: - Reflection enumeration (atomic form factors)

    private static func atomicFormFactorPattern(cell: Cell, atoms: [Atom], fracCoords: [SIMD3<Double>],
                                                wavelength: Float, max2T: Float, L: Int,
                                                sigma: Float, step: Float, curveSamples: Int,
                                                symmetryOps: [CrystalSymmetryOperation]?,
                                                sourceDesc: String) -> XRDPattern {
        let recip = cell.reciprocalVectors
        let aStar = SIMD3<Double>(Double(recip.a.x), Double(recip.a.y), Double(recip.a.z))
        let bStar = SIMD3<Double>(Double(recip.b.x), Double(recip.b.y), Double(recip.b.z))
        let cStar = SIMD3<Double>(Double(recip.c.x), Double(recip.c.y), Double(recip.c.z))
        let inv = cell.inverseMatrix!

        var reflections: [(h: Int, k: Int, l: Int, f2: Double, g2: Double)] = []

        var h = -L
        while h <= L {
            var k = -L
            while k <= L {
                var l = -L
                while l <= L {
                    if h == 0 && k == 0 && l == 0 {
                        l += 1
                        continue
                    }
                    let g = aStar * Double(h) + bStar * Double(k) + cStar * Double(l)
                    let g2 = simd_length_squared(g)
                    if g2 == 0 { l += 1; continue }
                    let d = Float(2 * Double.pi / sqrt(g2))
                    let sinTheta = wavelength / (2 * d)
                    if sinTheta > 1 || sinTheta < 0 { l += 1; continue }
                    let twoTheta = 2 * asin(sinTheta) * 180 / .pi
                    if twoTheta > max2T { l += 1; continue }

                    // Structure factor.
                    var re = 0.0, im = 0.0
                    for atom in atoms {
                        let frac = inv * SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
                        let phase = 2 * Double.pi * (Double(h) * frac.x + Double(k) * frac.y + Double(l) * frac.z)
                        let s = sinTheta / wavelength
                        let fj = Double(scatteringFactor(Z: atom.atomicNumber, s: s))
                        re += fj * cos(phase)
                        im += fj * sin(phase)
                    }
                    let f2 = re * re + im * im
                    reflections.append((h: h, k: k, l: l, f2: f2, g2: g2))
                    l += 1
                }
                k += 1
            }
            h += 1
        }

        // Group by d-spacing (|G|² within a tight relative tolerance). Each group
        // is one powder reflection; the representative is the canonical (smallest
        // |G|) member and the multiplicity is its full orbit size.
        let grouped = groupReflections(reflections, symmetryOps: symmetryOps, cell: cell)
        return buildPattern(grouped: grouped, wavelength: wavelength, max2T: max2T, sigma: sigma,
                            step: step, curveSamples: curveSamples, sourceDesc: sourceDesc)
    }

    /// Group raw (hkl) by |G|² within 1e-6 relative tolerance. Each group is one
    /// powder reflection. When `symmetryOps` is provided the group is partitioned
    /// into distinct orbits under the rotation parts: members of one orbit are
    /// related by a symmetry op and share |F|². The reported intensity factor is
    /// Σ_over_orbits (rep.f2 × orbitSize) and multiplicity is Σ orbitSizes, so the
    /// Lorentz–polarisation factor (applied later) multiplies a fully weighted
    /// intensity. hklLabels collects the canonical "h k l" of every orbit member.
    /// When `symmetryOps` is nil a single representative is used with the Laue
    /// fallback multiplicity (an approximation exact only for the Laue class).
    private static func groupReflections(_ refs: [(h: Int, k: Int, l: Int, f2: Double, g2: Double)],
                                         symmetryOps: [CrystalSymmetryOperation]?,
                                         cell: Cell) -> [(h: Int, k: Int, l: Int, intensity: Double, g2: Double, mult: Int, labels: [String])] {
        // Sort by g2 so equal-d reflections are adjacent.
        let sorted = refs.sorted { $0.g2 < $1.g2 }
        var result: [(Int, Int, Int, Double, Double, Int, [String])] = []
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, abs(sorted[j].g2 - sorted[i].g2) <= 1e-6 * sorted[i].g2 {
                j += 1
            }
            let group = Array(sorted[i..<j])

            // Orbit ID for a member: the lexicographic minimum of its sign-
            // canonicalized orbit {op·m}. Members sharing an ID are in one orbit.
            // Compared as a flat integer key (h·10⁶ + k·10³ + l) for simplicity.
            func orbitID(_ h: Int, _ k: Int, _ l: Int, _ ops: [CrystalSymmetryOperation]) -> Int {
                let canon = makeCanonical(h, k, l)
                var best = canon.0 &* 1000000 &+ canon.1 &* 1000 &+ canon.2
                for op in ops {
                    guard op.rotation.count == 9 else { continue }
                    let r = op.rotation
                    let hh = r[0] * h + r[1] * k + r[2] * l
                    let kk = r[3] * h + r[4] * k + r[5] * l
                    let ll = r[6] * h + r[7] * k + r[8] * l
                    let c = makeCanonical(hh, kk, ll)
                    let key = c.0 &* 1000000 &+ c.1 &* 1000 &+ c.2
                    if key < best { best = key }
                }
                return best
            }

            if let ops = symmetryOps, !ops.isEmpty {
                // Partition the group into distinct orbits keyed by orbitID.
                var orbits: [Int: (rep: (Int, Int, Int), f2: Double)] = [:]
                for m in group {
                    let oid = orbitID(m.h, m.k, m.l, ops)
                    if orbits[oid] == nil {
                        orbits[oid] = (rep: (m.h, m.k, m.l), f2: m.f2)
                    }
                }
                var intensity = 0.0
                var mult = 0
                var labels: [String] = []
                for orbit in orbits.values {
                    let size = explicitMultiplicity(h: orbit.rep.0, k: orbit.rep.1, l: orbit.rep.2, ops: ops)
                    intensity += orbit.f2 * Double(size)
                    mult += size
                    labels.append("\(makeCanonical(orbit.rep.0, orbit.rep.1, orbit.rep.2).0) \(makeCanonical(orbit.rep.0, orbit.rep.1, orbit.rep.2).1) \(makeCanonical(orbit.rep.0, orbit.rep.1, orbit.rep.2).2)")
                }
                labels.sort()
                // Representative hkl = canonical form of the first orbit.
                let firstOrbit = orbits.values.first!.rep
                let canon = makeCanonical(firstOrbit.0, firstOrbit.1, firstOrbit.2)
                result.append((canon.0, canon.1, canon.2, intensity, group[0].g2, mult, labels))
            } else {
                // No explicit ops: representative-only with the Laue fallback.
                let rep = group[0]
                let mult = laueMultiplicity(system: crystalSystem(cell: cell), h: rep.h, k: rep.k, l: rep.l)
                let canon = makeCanonical(rep.h, rep.k, rep.l)
                result.append((canon.0, canon.1, canon.2, rep.f2 * Double(mult), rep.g2, mult, ["\(canon.0) \(canon.1) \(canon.2)"]))
            }
            i = j
        }
        return result
    }

    // MARK: - Electron-density projection

    /// Electron-density projection via a separable 3D DFT. The full triple sum
    /// O(N·(2L+1)³) is reduced to three 1D stages:
    ///   stage 1 (reduce x):  for each (iy,iz) and each rh, A = Σ_ix ρ·exp(2πi·rh·fx)
    ///   stage 2 (reduce y):  for each (iz,rh) and each rk, B = Σ_iy A·exp(2πi·rk·fy)
    ///   stage 3 (reduce z):  for each (rh,rk) and each rl, F = Σ_iz B·exp(2πi·rl·fz)
    /// i.e. O(N·(2L+1) + ny·nz·(2L+1)² + nz·(2L+1)³). The mean density is
    /// subtracted so a constant field projects to zero (DC is never observable).
    private static func electronDensityPattern(cell: Cell, grid: ScalarField,
                                               inv: simd_double3x3, wavelength: Float, max2T: Float,
                                               L: Int, sigma: Float, step: Float, curveSamples: Int,
                                               symmetryOps: [CrystalSymmetryOperation]?,
                                               perm: [(Int, Int)]) -> XRDPattern {
        let recip = cell.reciprocalVectors
        let aStar = SIMD3<Double>(Double(recip.a.x), Double(recip.a.y), Double(recip.a.z))
        let bStar = SIMD3<Double>(Double(recip.b.x), Double(recip.b.y), Double(recip.b.z))
        let cStar = SIMD3<Double>(Double(recip.c.x), Double(recip.c.y), Double(recip.c.z))
        // inv is the INVERSE direct-cell matrix, so det(inv) = 1/V_cell; the
        // cell volume (the correct DFT prefactor V/N) is its reciprocal.
        let V = 1.0 / abs(inv.determinant)
        let N = grid.nx * grid.ny * grid.nz
        let scale = V / Double(N)

        let flat = grid.values
        let meanDensity = flat.isEmpty ? Double(0) : flat.reduce(0) { $0 + Double($1) } / Double(flat.count)

        let nx = grid.nx, ny = grid.ny, nz = grid.nz
        let nRecip = 2 * L + 1

        // Per-axis phase tables: expTable[axisIndex][sample][ri] = (cos, sin) of
        // 2π·(ri−L)·(sample/naxis).
        func phaseTable(_ count: Int) -> [[(Double, Double)]] {
            (0..<count).map { idx in
                let f = count > 1 ? Double(idx) / Double(count) : 0
                return (0..<nRecip).map { ri in
                    let phi = 2 * Double.pi * Double(ri - L) * f
                    return (cos(phi), sin(phi))
                }
            }
        }
        let tableX = phaseTable(nx)
        let tableY = phaseTable(ny)
        let tableZ = phaseTable(nz)

        // Stage 1 — reduce x. A[iy][iz][rh] = Σ_ix (ρ−mean)·exp(2πi·rh·ix/nx).
        // Stored flat: index = ((iy·nz) + iz)·nRecip + rh.
        let aStride = nz * nRecip
        var Are = [Double](repeating: 0, count: ny * nz * nRecip)
        var Aim = [Double](repeating: 0, count: ny * nz * nRecip)
        for iy in 0..<ny {
            for iz in 0..<nz {
                for ix in 0..<nx {
                    let val = Double(flat[ix + nx * (iy + ny * iz)]) - meanDensity
                    let rowX = tableX[ix]
                    for rh in 0..<nRecip {
                        let idx = iy * aStride + iz * nRecip + rh
                        let (cs, sn) = rowX[rh]
                        Are[idx] += val * cs
                        Aim[idx] += val * sn
                    }
                }
            }
        }

        // Stage 2 — reduce y. B[iz][rh][rk] = Σ_iy A·exp(2πi·rk·iy/ny).
        // Stored flat: index = (iz·nRecip + rh)·nRecip + rk.
        let bStride = nRecip * nRecip
        var Bre = [Double](repeating: 0, count: nz * nRecip * nRecip)
        var Bim = [Double](repeating: 0, count: nz * nRecip * nRecip)
        for iz in 0..<nz {
            for rh in 0..<nRecip {
                for iy in 0..<ny {
                    let aIdx = iy * aStride + iz * nRecip + rh
                    let aRe = Are[aIdx]
                    let aIm = Aim[aIdx]
                    let rowY = tableY[iy]
                    for rk in 0..<nRecip {
                        let idx = iz * bStride + rh * nRecip + rk
                        let (cs, sn) = rowY[rk]
                        Bre[idx] += aRe * cs - aIm * sn
                        Bim[idx] += aRe * sn + aIm * cs
                    }
                }
            }
        }

        // Stage 3 — reduce z. F[rh][rk][rl] = Σ_iz B·exp(2πi·rl·iz/nz).
        // Stored flat: index = ((rh·nRecip) + rk)·nRecip + rl.
        let cStride = nRecip * nRecip
        var Fre = [Double](repeating: 0, count: nRecip * nRecip * nRecip)
        var Fim = [Double](repeating: 0, count: nRecip * nRecip * nRecip)
        for rh in 0..<nRecip {
            for rk in 0..<nRecip {
                for iz in 0..<nz {
                    let bIdx = iz * bStride + rh * nRecip + rk
                    let bRe = Bre[bIdx]
                    let bIm = Bim[bIdx]
                    let rowZ = tableZ[iz]
                    for rl in 0..<nRecip {
                        let idx = rh * cStride + rk * nRecip + rl
                        let (cs, sn) = rowZ[rl]
                        Fre[idx] += bRe * cs - bIm * sn
                        Fim[idx] += bRe * sn + bIm * cs
                    }
                }
            }
        }

        // Collect observable reflections, mapping grid indices back to crystal
        // (h,k,l) via the inverse signed permutation (signs are self-inverse).
        var reflections: [(h: Int, k: Int, l: Int, f2: Double, g2: Double)] = []
        for rh in 0..<nRecip {
            for rk in 0..<nRecip {
                for rl in 0..<nRecip {
                    let ih = rh - L, ik = rk - L, il = rl - L
                    if ih == 0 && ik == 0 && il == 0 { continue }
                    // Grid axis i maps to crystal axis perm[i].0 with sign perm[i].1.
                    var hkl = [0, 0, 0]
                    hkl[perm[0].0] = perm[0].1 * ih
                    hkl[perm[1].0] = perm[1].1 * ik
                    hkl[perm[2].0] = perm[2].1 * il
                    let h = hkl[0], k = hkl[1], l = hkl[2]
                    let idx = rh * cStride + rk * nRecip + rl
                    let f2 = scale * scale * (Fre[idx] * Fre[idx] + Fim[idx] * Fim[idx])
                    let g = aStar * Double(h) + bStar * Double(k) + cStar * Double(l)
                    let g2 = simd_length_squared(g)
                    if g2 == 0 { continue }
                    let d = Float(2 * Double.pi / sqrt(g2))
                    let sinTheta = wavelength / (2 * d)
                    if sinTheta > 1 || sinTheta < 0 { continue }
                    let twoTheta = 2 * asin(sinTheta) * 180 / .pi
                    if twoTheta > max2T { continue }
                    reflections.append((h: h, k: k, l: l, f2: f2, g2: g2))
                }
            }
        }

        let grouped = groupReflections(reflections, symmetryOps: symmetryOps, cell: cell)
        return buildPattern(grouped: grouped, wavelength: wavelength, max2T: max2T, sigma: sigma,
                            step: step, curveSamples: curveSamples, sourceDesc: "electron density")
    }

    // MARK: - Peak assembly, LP, and curve

    /// Assemble peaks and the Gaussian-broadened profile from grouped
    /// reflections. The grouped intensity already includes the multiplicity
    /// weighting (Σ f2·mult over the member orbits); only the LP factor remains.
    private static func buildPattern(grouped: [(h: Int, k: Int, l: Int, intensity: Double, g2: Double, mult: Int, labels: [String])],
                                     wavelength: Float, max2T: Float, sigma: Float,
                                     step: Float, curveSamples: Int, sourceDesc: String) -> XRDPattern {
        var rawPeaks: [(twoTheta: Float, d: Float, intensity: Float, mult: Int, h: Int, k: Int, l: Int, labels: [String])] = []
        for g in grouped {
            let g2 = g.g2
            let d = Float(2 * Double.pi / sqrt(g2))
            if d <= 0 || !d.isFinite { continue }
            let sinTheta = wavelength / (2 * d)
            if sinTheta > 1 || sinTheta < 0 || sinTheta < 1e-6 { continue }
            let twoTheta = 2 * asin(min(1, sinTheta)) * 180 / .pi
            if twoTheta > max2T { continue }
            let cosTheta = cos(Float(asin(min(1, sinTheta))))
            if cosTheta < 1e-6 { continue }
            let twoT = Float(twoTheta)
            let cos2t = cos(twoT * .pi / 180)
            let lp = (1 + cos2t * cos2t) / (sinTheta * sinTheta * cosTheta)
            let intensity = Float(g.intensity) * lp
            rawPeaks.append((twoTheta: twoT, d: d, intensity: intensity, mult: g.mult,
                             h: g.h, k: g.k, l: g.l, labels: g.labels))
        }

        rawPeaks.sort { $0.twoTheta < $1.twoTheta }

        // Drop numerical-noise peaks (intensity < 1e-6 of the maximum): these
        // arise from systematic absences where |F|² is analytically zero. When
        // the maximum itself is zero, there is no signal — return no peaks.
        let peakMax = rawPeaks.map { $0.intensity }.max() ?? 0
        guard peakMax > 0 else {
            return XRDPattern(wavelength: wavelength, peaks: [], curve: [],
                              maxIntensity: 0, maxTwoTheta: max2T,
                              sourceDescription: sourceDesc, unavailableReason: nil)
        }
        rawPeaks = rawPeaks.filter { $0.intensity * 1e6 >= peakMax }

        guard !rawPeaks.isEmpty else {
            return XRDPattern(wavelength: wavelength, peaks: [], curve: [], maxIntensity: 0,
                              maxTwoTheta: max2T, sourceDescription: sourceDesc, unavailableReason: nil)
        }

        let maxI = rawPeaks.map { $0.intensity }.max() ?? 0
        let scale = maxI > 0 ? 100 / maxI : 0

        var curvePoints: [(twoTheta: Float, intensity: Float)] = []
        if sigma > 0 {
            for i in 0..<curveSamples {
                let t = Float(i) * step
                var acc = Float(0)
                for p in rawPeaks {
                    let dt = t - p.twoTheta
                    acc += p.intensity * exp(-(dt * dt) / (2 * sigma * sigma))
                }
                curvePoints.append((t, acc))
            }
        }
        let curveMax = curvePoints.map { $0.1 }.max() ?? 0

        let peaks = rawPeaks.map { m in
            XRDPeak(h: m.h, k: m.k, l: m.l, hklLabels: m.labels, dSpacing: m.d,
                    twoTheta: m.twoTheta, intensity: m.intensity, multiplicity: m.mult,
                    relativeIntensity: m.intensity * scale)
        }

        return XRDPattern(wavelength: wavelength, peaks: peaks, curve: curvePoints,
                          maxIntensity: max(curveMax, maxI), maxTwoTheta: max2T,
                          sourceDescription: sourceDesc, unavailableReason: nil)
    }
}

private extension XRDPattern {
    static func unavailable(wavelength: Float, reason: String) -> XRDPattern {
        XRDPattern(wavelength: wavelength, peaks: [], curve: [], maxIntensity: 0,
                   maxTwoTheta: 0, sourceDescription: "atomic form factors",
                   unavailableReason: reason)
    }
}
