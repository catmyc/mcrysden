import AppKit
import Darwin

final class App: NSObject, NSApplicationDelegate {
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
        FormatInfo(flag: "--xsf",     extensions: ["xsf"],                       format: .xsf),
        FormatInfo(flag: "--axsf",    extensions: ["axsf"],                      format: .axsf),
        FormatInfo(flag: "--xyz",     extensions: ["xyz"],                       format: .xyz),
        FormatInfo(flag: "--pdb",     extensions: ["pdb"],                       format: .pdb),
        FormatInfo(flag: "--pwi",     extensions: ["pwi", "in", "inp"],          format: .pwi),
        FormatInfo(flag: "--pwo",     extensions: ["pwo", "out"],                format: .pwo),
        FormatInfo(flag: "--cif",     extensions: ["cif"],                       format: .cif),
        FormatInfo(flag: "--poscar",  extensions: ["poscar", "contcar", "vasp"], format: .poscar),
        FormatInfo(flag: "--cube",    extensions: ["cube"],                      format: .cube),
        FormatInfo(flag: "--bxsf",    extensions: ["bxsf", "bxsf.gz"],           format: .bxsf),
        FormatInfo(flag: "--struct",  extensions: ["struct"],                    format: .struct_),
        FormatInfo(flag: "--crystal", extensions: ["r1"],                        format: .crystal),
        FormatInfo(flag: "--orca",    extensions: ["orca"],                      format: .orca),
        FormatInfo(flag: "--fhi",     extensions: ["fhi", "coord"],              format: .fhi),
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
    private static let openPanelExtensions: [String] = formatTable.flatMap { $0.extensions }

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
        var scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: cliFrame))
        var camera: Camera? = nil
        if let stateURL {
            try StateStore.load(into: &scene, camera: &camera, from: stateURL)
        }
        // Honor a saved animation frame: re-parse it and rebuild the structure.
        if scene.currentFrame > 0 && scene.currentFrame != cliFrame {
            let fc = Parser.frameCount(url, as: format)
            if scene.currentFrame < fc {
                // Snapshot the appearance/control state the StateStore just restored —
                // a fresh Scene(loaded:) would otherwise wipe display mode, colors,
                // lighting, visibility flags, isosurface settings and currentFrame.
                let restoredAppearance = scene
                scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: scene.currentFrame))
                if restoredAppearance.superCell.total > 1 {
                    scene = scene.widenSuperCell(restoredAppearance.superCell)
                }
                if let sl = restoredAppearance.slab { scene = scene.applySlab(sl) }
                // re-apply the appearance fields (kept while only geometry changed)
                scene.displayMode = restoredAppearance.displayMode
                scene.background = restoredAppearance.background
                scene.backgroundBottom = restoredAppearance.backgroundBottom
                scene.backgroundType = restoredAppearance.backgroundType
                scene.lighting = restoredAppearance.lighting
                scene.showCellFrame = restoredAppearance.showCellFrame
                scene.showAxes = restoredAppearance.showAxes
                scene.showLabels = restoredAppearance.showLabels
                scene.showStructure = restoredAppearance.showStructure
                scene.showBrillouinZone = restoredAppearance.showBrillouinZone
                scene.showIsoSurface = restoredAppearance.showIsoSurface
                scene.isoLevel = restoredAppearance.isoLevel
                scene.atomScale = restoredAppearance.atomScale
                scene.bondRadius = restoredAppearance.bondRadius
                scene.selectedAtoms = restoredAppearance.selectedAtoms
                scene.measurementMode = restoredAppearance.measurementMode
                scene.measurementResult = restoredAppearance.measurementResult
                scene.currentFrame = restoredAppearance.currentFrame
                // Do NOT restore scalarField/fermiSurface from the initial scene: the
                // freshly parsed frame carries its own volumetric data, and an animated
                // XSF can have frame-specific grids. Keep the new frame's fields.
            }
        }
        return (scene, camera)
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
                switch outURL.pathExtension.lowercased() {
                case "pdf", "svg", "eps", "ps":
                    try RasterExporter.export(scene: scene, camera: camera, to: outURL, size: exportSize)
                default:
                    try PngExporter.export(scene: scene, camera: camera, to: outURL, size: exportSize)
                }
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
                wc.loadFile(scene, from: inURL, format: format, frameIndex: scene.currentFrame > 0 ? scene.currentFrame : frame)
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
        panel.allowedContentTypes = Self.openPanelExtensions.compactMap { .init(filenameExtension: $0) }
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
    static let appVersion = "1.1.2"

    static func printHelp() {
        // Help text is GENERATED from the format table so flags, extensions and the
        // units note can never drift out of sync with the parser.
        let exts = formatTable.map { $0.extensions.first! }.joined(separator: " ")
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
