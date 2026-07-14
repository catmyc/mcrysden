import AppKit
import Darwin

final class App: NSObject, NSApplicationDelegate, NSOpenSavePanelDelegate {
    var mainWC: MainWindowController?

    /// Quit automatically when the user closes the last window (issue 1).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// A single source of truth for every supported format: its force-flag, the file
    /// extensions (primary first) the Open panel offers, and the parser to use.
    /// `formatFlags`, `forcedFormat`, the Open panel and --help are all derived from
    /// this table so they can never drift apart.
    private struct FormatInfo {
        let flag: String
        let extensions: [String]
        let format: ParseFormat
    }
    private static let formatTable: [FormatInfo] = [
        FormatInfo(flag: "--xsf",     extensions: ["xsf", "xsf.gz"],             format: .xsf),
        FormatInfo(flag: "--axsf",    extensions: ["axsf"],                      format: .axsf),
        FormatInfo(flag: "--xyz",     extensions: ["xyz"],                       format: .xyz),
        FormatInfo(flag: "--pdb",     extensions: ["pdb"],                       format: .pdb),
        FormatInfo(flag: "--pwi",     extensions: ["pwi", "in", "inp"],          format: .pwi),
        FormatInfo(flag: "--pwo",     extensions: ["pwo", "out"],                format: .pwo),
        FormatInfo(flag: "--cif",     extensions: ["cif"],                       format: .cif),
        FormatInfo(flag: "--poscar",  extensions: ["poscar", "contcar", "vasp"], format: .poscar),
        FormatInfo(flag: "--cube",    extensions: ["cube", "g98"],               format: .cube),
        FormatInfo(flag: "--bxsf",    extensions: ["bxsf", "bxsf.gz"],           format: .bxsf),
        FormatInfo(flag: "--struct",  extensions: ["struct"],                    format: .struct_),
        FormatInfo(flag: "--crystal", extensions: ["r1"],                        format: .crystal),
        FormatInfo(flag: "--orca",    extensions: ["orca"],                      format: .orca),
        FormatInfo(flag: "--fhi",     extensions: ["fhi", "coord"],              format: .fhi),
        FormatInfo(flag: "--bands",   extensions: ["bands"],                     format: .bands),
        FormatInfo(flag: "--dos",     extensions: ["dos", "pdos", "pdos_tot"], format: .dos),
    ]
    /// Force-format flags (take no value).
    private static let formatFlags: Set<String> = Set(formatTable.map { $0.flag })

    /// Resolve a forced parser format from the CLI args, if any.
    private static func forcedFormat(from args: [String]) -> ParseFormat? {
        for info in formatTable where args.contains(info.flag) { return info.format }
        return nil
    }

    /// All extensions the Open panel should offer, in display order (primary
    /// extension of each format first, then alternates).
    static let openPanelExtensions: [String] = {
        var seen = Set<String>()
        return formatTable.flatMap { $0.extensions }.compactMap { advertised in
            // NSOpenPanel matches the final extension, so `xsf.gz`/`bxsf.gz` must
            // contribute `gz`; Parser.from validates the inner extension after open.
            let ext = advertised.split(separator: ".").last.map(String.init) ?? advertised
            return seen.insert(ext).inserted ? ext : nil
        }
    }()

    /// Find the input structure file: the first arg that is not a known flag and
    /// is not consumed by `--export <path>`. Allows the force-format flags to be
    /// placed anywhere, e.g. `mcrysden --pwi file.in`.
    private static func inputFile(from args: [String]) -> String? {
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if a == "--export" { skipNext = true; continue }
            if a == "--frame" { skipNext = true; continue }   // its own value follows
            if a == "--help" || a == "-h" { continue }
            if Self.formatFlags.contains(a) { continue }
            return a
        }
        return nil
    }

    /// Parse `--frame N`: the animation frame to open at launch. Returns the
    /// requested index (>= 0) when --frame is present, or -1 (sentinel) when it is
    /// absent, so the loader can distinguish "default open" (cycle 0) from an
    /// explicit --frame 0 (also cycle 0) -- both now route correctly. The per-format
    /// frame loader clamps the value to the file's actual count downstream.
    private static func frameIndex(from args: [String]) -> Int {
        if let idx = args.firstIndex(of: "--frame"), idx + 1 < args.count, let n = Int(args[idx + 1]) {
            return max(0, n)
        }
        return -1   // no --frame specified: default-open sentinel
    }

    /// Parse a structure at the CLI frame, apply a companion state (which widens
    /// the supercell, applies the slab, and may encode a saved animation frame),
    /// then — if the state restored a saved frame — re-parse THAT frame and
    /// re-apply the structural transforms. Without this, the saved currentFrame
    /// would be metadata-only and the saved frame's geometry would never show.
    private static func loadScene(from url: URL, format: ParseFormat?, cliFrame: Int,
                                  stateURL: URL?) throws -> (scene: Scene, camera: Camera?) {
        // The frame the initial load actually shows: cliFrame is -1 (default open) or an
        // explicit --frame N (>= 0). Record it on the scene so the GUI scrubber and the
        // displayed geometry agree -- without this the scene always reports frame 0 no
        // matter which cycle is shown.
        let loadedFrame = cliFrame < 0 ? 0 : cliFrame
        var scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: cliFrame))
        scene.currentFrame = loadedFrame
        var camera: Camera? = nil
        if let stateURL {
            try StateStore.load(into: &scene, camera: &camera, from: stateURL)
        }
        // Resolve the displayed frame (clamp a saved frame + reparse it) via the shared
        // helper so the GUI path and the frame-state tests run IDENTICAL logic.
        let fc = Parser.frameCount(url, as: format)
        try resolveAnimationFrame(scene: &scene, from: url, format: format,
                                  loadedFrame: loadedFrame, fc: fc)
        return (scene, camera)
    }

    /// Resolve which animation frame a scene (just loaded, and optionally state-restored)
    /// should display. A saved `currentFrame` is clamped into `0..<fc` (and warned on); if
    /// it differs from the frame we initially loaded, that cycle is re-parsed and the
    /// appearance/structural settings restored from state are carried over. INTERNAL so
    /// the frame-state tests exercise the EXACT production logic instead of a mirror.
    static func resolveAnimationFrame(scene: inout Scene, from url: URL, format: ParseFormat?,
                                      loadedFrame: Int, fc: Int) throws {
        if fc == 0 {
            // Non-animated file: a malformed saved state or --frame N must never leave a
            // stale nonzero/negative index in the scene (it would desync the scrubber).
            if scene.currentFrame != 0 {
                print("[mcrysden] warning: saved frame \(scene.currentFrame) on a non-animated file; reset to 0")
                scene.currentFrame = 0
            }
        } else if scene.currentFrame < 0 || scene.currentFrame >= fc {
            // Animated file: clamp a saved index into the valid range.
            let clamped = min(max(0, scene.currentFrame), fc - 1)
            print("[mcrysden] warning: saved frame \(scene.currentFrame) out of range (0..<\(fc)); clamped to \(clamped)")
            scene.currentFrame = clamped
        }
        // Honor a saved frame that differs from what we loaded (a saved 0 overrides --frame N).
        if scene.currentFrame != loadedFrame, scene.currentFrame < fc {
            let restored = scene
            scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: scene.currentFrame))
            if restored.superCell.total > 1 { scene = scene.widenSuperCell(restored.superCell) }
            if let sl = restored.slab { scene = scene.applySlab(sl) }
            // carry over appearance/structural settings (kept while only geometry changes)
            scene.displayMode = restored.displayMode
            scene.background = restored.background
            scene.backgroundBottom = restored.backgroundBottom
            scene.backgroundType = restored.backgroundType
            scene.lighting = restored.lighting
            scene.showCellFrame = restored.showCellFrame
            scene.showAxes = restored.showAxes
            scene.showLabels = restored.showLabels
            scene.showStructure = restored.showStructure
            scene.showBrillouinZone = restored.showBrillouinZone
            scene.showIsoSurface = restored.showIsoSurface
            scene.isoLevel = restored.isoLevel
            // Force-arrow settings: carry across the frame rebuild so restoring a saved
            // animation frame (headless --frame or GUI saved currentFrame) keeps the
            // visibility/scale the user set, matching the other appearance fields.
            scene.showForces = restored.showForces
            scene.forceScale = restored.forceScale
            scene.atomScale = restored.atomScale
            scene.bondRadius = restored.bondRadius
            scene.selectedAtoms = restored.selectedAtoms
            scene.measurementMode = restored.measurementMode
            scene.measurementResult = restored.measurementResult
            scene.currentFrame = restored.currentFrame
            // Do NOT restore scalarField/fermiSurface from the initial scene: the freshly
            // parsed frame carries its own volumetric data; keep the new frame's fields.
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)         // bring to front so menu bar changes
        updateAnalysisCheckmarks()
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            Self.printHelp(); NSApp.terminate(nil); return
        }
        let format = Self.forcedFormat(from: args)
        let frame = Self.frameIndex(from: args)
        // headless export path
        var exportHasHappened = false
        if let idx = args.firstIndex(of: "--export"), idx + 1 < args.count,
           let input = Self.inputFile(from: args) {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let inURL = URL(fileURLWithPath: input)
            do {
                let stURL = args.firstIndex(where: { $0.hasSuffix(".mvis-state") })
                    .map { URL(fileURLWithPath: args[$0]) }
                let (scene, camera) = try Self.loadScene(from: inURL, format: format, cliFrame: frame, stateURL: stURL)
                let exportSize = CGSize(width: 800, height: 800)
                try Self.exportScene(scene, camera: camera, to: outURL, size: exportSize)
                exportHasHappened = true
            } catch {
                print("[mcrysden] export failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
        if exportHasHappened { NSApp.terminate(nil); return }
        // GUI path
        if let input = Self.inputFile(from: args) {
            let inURL = URL(fileURLWithPath: input)
            do {
                let stURL = args.firstIndex(where: { $0.hasSuffix(".mvis-state") })
                    .map { URL(fileURLWithPath: args[$0]) }
                // loadScene honors a saved animation frame by re-parsing it (the
                // saved frame becomes geometry, not just metadata).
                let (scene, camera) = try Self.loadScene(from: inURL, format: format, cliFrame: frame, stateURL: stURL)
                let wc = MainWindowController(scene: Scene())
                mainWC = wc
                // Pass the RESOLVED frame (clFrame, or the restored frame if the
                // state encoded one) so the scrubber opens where the user left off.
                // The scene's currentFrame is now accurate (>= 0) whether it came from
                // the CLI --frame, a saved state, or the default-open frame 0 -- so the
                // scrubber initializes in sync with what's actually displayed.
                wc.loadFile(scene, from: inURL, format: format, frameIndex: scene.currentFrame)
                if let camera {
                    wc.camera = camera
                    // Sync the orthographic toggle from the RESTORED camera (not the
                    // scene.camera that syncFromScene already mirrored), else the
                    // next sidebar touch re-syncs projection from a stale flag.
                    wc.state.orthographic = !camera.perspective
                    wc.setNeedsRender()
                }
            } catch {
                print("[mcrysden] failed to open \(input): \(error)")
            }
        } else {
            mainWC = MainWindowController(scene: Scene())
        }
    }

    // MARK: - Menu bar

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        // File
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        let openItem = file.addItem(withTitle: "Open\u{2026}", action: #selector(openDocument), keyEquivalent: "o")
        openItem.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        // View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        let lbl = view.addItem(withTitle: "Toggle Element Labels", action: #selector(toggleLabelsFromMenu), keyEquivalent: "l")
        lbl.target = self
        // Analysis
        let analysisItem = NSMenuItem(); main.addItem(analysisItem)
        let analysis = NSMenu(title: "Analysis")
        analysisItem.submenu = analysis
        // Build the menu with a stable tag per item (1..4) so we can update
        // the checkmark without matching titles.
        let modeList: [(String, Int)] = [
            ("Selection", 1),
            ("Distance", 2),
            ("Angle", 3),
            ("Dihedral", 4),
        ]
        for (title, tag) in modeList {
            let it = analysis.addItem(withTitle: title, action: #selector(selectAnalysisMode(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
        }
        return main
    }

    /// File > Open...
    @objc private func openDocument(_ sender: Any?) {
        guard let wc = mainWC else { return }
        let panel = NSOpenPanel()
        // Use a broad UTI and let ParseFormat perform the authoritative filename
        // filtering. QE projected-DOS suffixes encode atom/wfc metadata and cannot
        // be represented by a finite allowedContentTypes list.
        panel.allowedContentTypes = [.data]
        panel.delegate = self
        panel.beginSheetModal(for: wc.window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let scene = Scene(loaded: try Parser.load(url))
                wc.loadFile(scene, from: url, format: nil, frameIndex: 0)
            } catch {
                print("[mcrysden] open failed: \(error)")
            }
        }
    }

    static func supportsOpenURL(_ url: URL) -> Bool {
        url.hasDirectoryPath || ParseFormat.from(url: url) != nil
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Self.supportsOpenURL(url)
    }

    @MainActor
    @discardableResult
    static func exportScene(_ scene: Scene, camera: Camera?, to url: URL, size: CGSize) throws -> CGImage {
        if let dos = scene.densityOfStates {
            return try DOSExporter.export(dos, to: url, size: size)
        }
        switch url.pathExtension.lowercased() {
        case "pdf", "svg", "eps", "ps":
            return try RasterExporter.export(scene: scene, camera: camera, to: url, size: size)
        default:
            return try PngExporter.export(scene: scene, camera: camera, to: url, size: size)
        }
    }

    /// View > Toggle Element Labels
    @objc private func toggleLabelsFromMenu(_ sender: Any?) {
        mainWC?.state.showLabels.toggle()      // propagates via onChange -> syncFromState
    }

    /// Mapping from menu tag to measurement mode.
    private static func modeFor(tag: Int) -> MeasurementMode {
        switch tag {
        case 2: return .distance
        case 3: return .angle
        case 4: return .dihedral
        default: return .none
        }
    }

    /// Analysis > Selection / Distance / Angle / Dihedral (sender carries tag).
    /// Toggling a measurement mode clears any previous selection and starts a
    /// fresh pick; once the required number of atoms is reached the result is
    /// computed automatically and shown in the bottom panel.
    @objc private func selectAnalysisMode(_ sender: NSMenuItem) {
        let mode = Self.modeFor(tag: sender.tag)
        guard let wc = mainWC else { return }
        // Route through `state` — the single source of truth — so the mode
        // survives a later sidebar sync (which otherwise overwrites scene with
        // stale state whenever any sidebar control changes). The state's
        // onChange -> syncFromState propagates the mode into the scene.
        wc.beginMeasurementMode(mode)        // clears selection + sets state
        updateAnalysisCheckmarks()
    }

    /// Reflect the active measurement mode with a checkmark in the Analysis menu.
    private func updateAnalysisCheckmarks() {
        // Read from `state` — the canonical source — so the checkmark reflects
        // the mode the menu just set, without depending on a pending sync.
        guard let analysis = NSApp.mainMenu?.item(withTitle: "Analysis")?.submenu,
              let mode = mainWC?.state.measurementMode else { return }
        let activeTag: Int = { switch mode {
            case .none: return 1; case .distance: return 2; case .angle: return 3; case .dihedral: return 4
        } }()
        for item in analysis.items { item.state = (item.tag == activeTag) ? .on : .off }
    }

    /// Current app version, surfaced in --help output.
    static let appVersion = "1.1.12"

    static func printHelp() {
        // Help text is GENERATED from the format table so flags, extensions and the
        // units note can never drift out of sync with the parser.
        let exts = formatTable.flatMap { $0.extensions }.joined(separator: " ")
        let flags = formatTable.map { $0.flag }.joined(separator: " ")
        print("""
        mcrysden v\(appVersion) — native macOS crystal/molecule viewer (Metal).
        Usage:
          mcrysden                                    # empty viewer
          mcrysden <file>                             # open a structure (by extension)
          mcrysden <file> <state.mvis-state>           # open with saved state
          mcrysden <file> --export out.png             # headless raster render
          mcrysden <file> --export out.pdf             # raster render in a vector container (pdf, svg, eps, ps)
          mcrysden --help
        Input formats are chosen by extension (\(exts)). Angstrom-based input
        (.cube/.bxsf/.struct) is kept in Angstrom; Bohr-based input is converted.
        Override the extension with a flag (any one):
          \(flags)
        For animated files (AXSF ANIMSTEPS, QE .pwo ionic steps, Orca opt cycles),
        open a specific frame with --frame N (0-based frame index).
        Export format is chosen by extension: .png (raster) or .pdf/.svg/.eps/.ps (vector).
        """)
    }
}
