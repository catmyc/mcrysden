import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

final class App: NSObject, NSApplicationDelegate, NSOpenSavePanelDelegate, NSMenuDelegate, NSWindowDelegate {
    var mainWC: MainWindowController? { get { windowRegistry.active } }
    private let exportOptions = ExportOptions()

    /// Present the command palette overlay.
    @MainActor
    @objc private func showCommandPalette(_ sender: Any?) {
        CommandPaletteView.show()
    }

    private var exportOptionsPanel: NSPanel?

    /// Present the export options panel as a modeless floating panel.
    @MainActor
    @objc private func showExportOptions(_ sender: Any?) {
        if let existing = exportOptionsPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Export Options"
        panel.contentView = NSHostingView(rootView: ExportOptionsView(options: exportOptions))
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        exportOptionsPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// File-menu items the menu delegate (self) updates on open: Revert reflects
    /// whether a file is loaded; Open Recent is rebuilt from NSDocumentController.
    private weak var revertItem: NSMenuItem?
    private weak var recentItem: NSMenuItem?

    /// Pending timer that resets the Copy Current View menu title after a flash.
    /// Cancelled before scheduling a new one so rapid copies don't race.
    private var copyResetTimer: Timer?
    /// The menu title to restore when the pending reset timer fires. Preserved
    /// across cancelled timers so a rapid repeat restores to the true original.
    private var copyResetOriginal: String?

    /// UserDefaults key for the last successfully-opened file, reopened on launch
    /// when no CLI input is given. Stores the file's path as a plain string.
    static let lastOpenedURLKey = "mcrysden.lastOpenedURL"

    struct LaunchOptions {
        var inputURL: URL?
        var stateURL: URL?
        var exportURL: URL?
        var format: ParseFormat?
        var frame = -1
        var help = false
    }

    enum CLIError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            if case .invalid(let message) = self { return message }
            return "invalid arguments"
        }
    }

    /// Quit automatically when the user closes the last window (issue 1).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // MARK: - Window controller registry

    /// Tracks live viewer windows so menu actions can route to the active window
    /// and the Window menu can list them. Windows are added on creation, removed
    /// on close, and tracked for activation via didBecomeKey notifications — so
    /// `active` never depends on NSApp (which is nil in tests / before launch).
    private final class WindowRegistry {
        private var controllers: [MainWindowController] = []
        private var activeController: MainWindowController?
        func add(_ wc: MainWindowController) {
            if !controllers.contains(where: { $0 === wc }) {
                controllers.append(wc)
                activeController = wc
            }
        }
        func remove(_ wc: MainWindowController) {
            controllers.removeAll { $0 === wc }
            if activeController === wc { activeController = controllers.last }
        }
        func makeActive(_ wc: MainWindowController) {
            if controllers.contains(where: { $0 === wc }) { activeController = wc }
        }
        var active: MainWindowController? { activeController ?? controllers.last }
        var windows: [NSWindow] { controllers.map { $0.window } }
    }
    private let windowRegistry = WindowRegistry()

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

    static func parseArguments(_ args: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var positionals: [String] = []
        var forced: ParseFormat?
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let argument = args[index]
            if !optionsEnded && argument == "--" {
                optionsEnded = true
            } else if !optionsEnded && (argument == "--help" || argument == "-h") {
                options.help = true
            } else if !optionsEnded && argument == "--export" {
                guard options.exportURL == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--export requires exactly one output path")
                }
                index += 1
                options.exportURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--frame" {
                guard options.frame == -1, index + 1 < args.count,
                      let frame = Int(args[index + 1]), frame >= 0, frame <= Int(Int32.max) else {
                    throw CLIError.invalid("--frame requires one non-negative 32-bit integer")
                }
                index += 1
                options.frame = frame
            } else if !optionsEnded, let info = formatTable.first(where: { $0.flag == argument }) {
                guard forced == nil else { throw CLIError.invalid("multiple force-format flags are not allowed") }
                forced = info.format
            } else if !optionsEnded && argument.hasPrefix("-") {
                throw CLIError.invalid("unknown option: \(argument)")
            } else {
                positionals.append(argument)
            }
            index += 1
        }
        guard positionals.count <= 2 else { throw CLIError.invalid("too many positional arguments") }
        if let first = positionals.first { options.inputURL = URL(fileURLWithPath: first) }
        if options.frame != -1 {
            guard options.inputURL != nil else { throw CLIError.invalid("--frame requires an input file") }
        }
        if forced != nil, options.inputURL == nil {
            throw CLIError.invalid("force-format flags require an input file")
        }
        if positionals.count == 1, positionals[0].lowercased().hasSuffix(".mvis-state") {
            throw CLIError.invalid("a state file requires an input file")
        }
        if positionals.count == 2 {
            guard positionals[1].lowercased().hasSuffix(".mvis-state") else {
                throw CLIError.invalid("second positional argument must be a .mvis-state file")
            }
            options.stateURL = URL(fileURLWithPath: positionals[1])
        }
        options.format = forced
        if let output = options.exportURL {
            guard options.inputURL != nil else { throw CLIError.invalid("--export requires an input file") }
            guard supportedExportExtensions.contains(output.pathExtension.lowercased()) else {
                throw CLIError.invalid("unsupported export extension: \(output.pathExtension)")
            }
        }
        return options
    }

    private static let supportedExportExtensions: Set<String> = ["png", "pdf", "svg", "eps", "ps"]
    private static let stateContentType = UTType(filenameExtension: "mvis-state")!
    private static let exportContentTypes: [UTType] = [
        .png, .pdf,
        UTType(filenameExtension: "svg")!,
        UTType(filenameExtension: "eps")!,
        UTType(filenameExtension: "ps")!,
    ]
    private static let maxExportDimension: CGFloat = 16_384
    /// Total-pixel ceiling for offscreen graph/bitmap allocation. Matches the per-frame
    /// export cap so a 16384×16384 (or any Int-overflowing) graph size is refused with a
    /// clear error instead of trapping on the Int cast or hanging on a huge allocation.
    private static let maxExportTotalPixels = 16_000_000

    /// Validate an export size for offscreen graph/bitmap allocation: must be finite,
    /// positive, representable as Int on each axis, within the per-axis cap, and the
    /// total pixel count must not overflow Int or exceed the ceiling. Returns the
    /// validated (width, height) as Int so callers never trap on an Int cast or
    /// allocate a pathological buffer. Used by every graph route before its first
    /// CGContext/NSBitmapImageRep allocation (DOSExporter mirrors this inside render()).
    static func validatedExportSize(_ size: CGSize) throws -> (width: Int, height: Int) {
        let w = size.width, h = size.height
        guard w.isFinite, h.isFinite else {
            throw CLIError.invalid("export size must be finite")
        }
        guard w > 0, h > 0 else {
            throw CLIError.invalid("export size must be positive")
        }
        guard w <= maxExportDimension, h <= maxExportDimension,
              w <= CGFloat(Int.max), h <= CGFloat(Int.max) else {
            throw CLIError.invalid("export size exceeds allowable dimensions")
        }
        let iw = Int(w.rounded()), ih = Int(h.rounded())
        // Re-check after rounding: 0.4 → 0 is a degenerate, non-drawable size.
        guard iw >= 1, ih >= 1 else {
            throw CLIError.invalid("export size rounds to zero pixels")
        }
        let total = iw.multipliedReportingOverflow(by: ih)
        guard !total.overflow, total.partialValue <= maxExportTotalPixels else {
            throw CLIError.invalid("export pixel count exceeds the allowed maximum")
        }
        return (iw, ih)
    }

    /// Parse a structure at the CLI frame, apply a companion state (which widens
    /// the supercell, applies the slab, and may encode a saved animation frame),
    /// then — if the state restored a saved frame — re-parse THAT frame and
    /// re-apply the structural transforms. Without this, the saved currentFrame
    /// would be metadata-only and the saved frame's geometry would never show.
    private static func loadScene(from url: URL, format: ParseFormat?, cliFrame: Int,
                                  stateURL: URL?, kPathSampling: inout Int) throws -> (scene: Scene, camera: Camera?) {
        if let stateURL, sameFile(url, stateURL) {
            throw CLIError.invalid("input and state alias the same file: \(url.path)")
        }
        let fc = Parser.frameCount(url, as: format)
        if cliFrame >= 0, fc == 0 || cliFrame >= fc {
            throw CLIError.invalid("--frame \(cliFrame) is out of range for \(url.lastPathComponent)")
        }
        // The frame the initial load actually shows: cliFrame is -1 (default open) or an
        // explicit --frame N (>= 0). Record it on the scene so the GUI scrubber and the
        // displayed geometry agree -- without this the scene always reports frame 0 no
        // matter which cycle is shown.
        let loadedFrame = cliFrame < 0 ? 0 : cliFrame
        var scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: cliFrame))
        scene.currentFrame = loadedFrame
        var camera: Camera? = nil
        if let stateURL {
            kPathSampling = try StateStore.load(into: &scene, camera: &camera, from: stateURL)
        }
        // Resolve the displayed frame (clamp a saved frame + reparse it) via the shared
        // helper so the GUI path and the frame-state tests run IDENTICAL logic.
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
            // The freshly parsed frame may carry a scalar field whose value range differs
            // from the frame we carried the level over (e.g. animated XSF). Clamp the
            // carried level into the new field's range so it stays meaningful; when the
            // level already fits, its value passes through unchanged. With a no-field
            // frame the level is inert (the renderer gates on scalarField), so leave it
            // untouched. Mirrors the reloadFrame clamp in MainWindowController.
            if let field = scene.scalarField {
                scene.isoLevel = min(field.maxValue, max(field.minValue, scene.isoLevel))
            }
            // Force-arrow settings: carry across the frame rebuild so restoring a saved
            // animation frame (headless --frame or GUI saved currentFrame) keeps the
            // visibility/scale the user set, matching the other appearance fields.
            scene.showForces = restored.showForces
            scene.forceScale = restored.forceScale
            scene.atomScale = restored.atomScale
            scene.bondRadius = restored.bondRadius
            scene.measurementMode = restored.measurementMode
            scene.showColorPlane = restored.showColorPlane
            // A rebuilt frame may have a different input reciprocal basis even
            // when its standardized symmetry signature is unchanged (for example
            // a physically rotated cell). Generated paths stay with the freshly
            // parsed frame; user paths are carried with their breaks/provenance
            // and safely remapped through Cartesian reciprocal space when possible.
            scene.transferKPathAcrossGeometryChange(from: restored)
            // A selection/measurement is only portable when EVERY saved index still
            // points at a real atom in the REBUILT frame (a different animation frame —
            // or a supercell/slab it predates — may shrink the atom count). Carry a
            // valid selection intact (preserving the saved picks and the locked
            // measurement); clear the lock and the selection if ANY saved index is
            // out of range for the new atom set. This mirrors the supercell/slab guards
            // in Scene+Init, which already cleared selectedAtoms when they rebuild.
            let atomCount = scene.atoms.count
            var savedIndices = restored.selectedAtoms
            if let r = restored.measurementResult { savedIndices.append(contentsOf: r.atomIndices) }
            if savedIndices.allSatisfy({ $0 >= 0 && $0 < atomCount }) {
                scene.selectedAtoms = restored.selectedAtoms
                scene.measurementResult = restored.measurementResult
            } else {
                scene.selectedAtoms = []
                scene.measurementResult = nil
            }
            scene.currentFrame = restored.currentFrame
            // Do NOT restore scalarField/fermiSurface from the initial scene: the freshly
            // parsed frame carries its own volumetric data; keep the new frame's fields.
        }
    }

    /// Resolve which file to open at launch. An explicit CLI input always wins;
    /// with no CLI input, fall back to the stored lastOpenedURL (implicit reopen).
    /// The `isReopen` flag lets the caller treat an implicit reopen failure as
    /// non-fatal (clear the key, open an empty viewer) rather than exiting.
    static func resolveLaunchURL(options: LaunchOptions) -> (url: URL?, isReopen: Bool) {
        if let explicit = options.inputURL {
            return (explicit, false)
        }
        guard let path = UserDefaults.standard.string(forKey: lastOpenedURLKey),
              !path.isEmpty else {
            return (nil, false)
        }
        return (URL(fileURLWithPath: path), true)
    }

    @objc func windowWillClose(_ note: Notification) {
        if let wc = (note.object as? NSWindow)?.delegate as? MainWindowController {
            windowRegistry.remove(wc)
        }
    }

    @objc func windowDidBecomeKey(_ note: Notification) {
        if let wc = (note.object as? NSWindow)?.delegate as? MainWindowController {
            windowRegistry.makeActive(wc)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)         // bring to front so menu bar changes
        updateAnalysisCheckmarks()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        let args = Array(CommandLine.arguments.dropFirst())
        let options: LaunchOptions
        do {
            options = try Self.parseArguments(args)
        } catch {
            print("[mcrysden] \(error)")
            exit(EXIT_FAILURE)
        }
        if options.help {
            Self.printHelp(); NSApp.terminate(nil); return
        }
        // headless export path
        if let outURL = options.exportURL, let inURL = options.inputURL {
            do {
                try Self.validateExportDestination(outURL, input: inURL, state: options.stateURL)
                var kPathSampling = 20
                let (scene, camera) = try Self.loadScene(from: inURL, format: options.format,
                                                         cliFrame: options.frame, stateURL: options.stateURL,
                                                         kPathSampling: &kPathSampling)
                let exportSize = CGSize(width: 800, height: 800)
                try Self.exportScene(scene, camera: camera, to: outURL, size: exportSize)
            } catch {
                print("[mcrysden] export failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // GUI path. Resolve which file to open: explicit CLI input always wins;
        // otherwise fall back to the stored lastOpenedURL (implicit reopen).
        let (inputURL, isReopen) = Self.resolveLaunchURL(options: options)
        if let inURL = inputURL {
            do {
                // loadScene honors a saved animation frame by re-parsing it (the
                // saved frame becomes geometry, not just metadata).
                var kPathSampling = 20
                let (scene, camera) = try Self.loadScene(from: inURL, format: options.format,
                                                         cliFrame: options.frame, stateURL: options.stateURL,
                                                         kPathSampling: &kPathSampling)
                let wc = MainWindowController(scene: Scene())
                windowRegistry.add(wc)
                wc.loadFile(scene, from: inURL, format: options.format, frameIndex: scene.currentFrame)
                // kPathSampling is a UI-only preference, not a scene field, so it is not
                // restored by syncFromScene; apply the value decoded from state here.
                wc.state.kPathSampling = kPathSampling
                if let camera {
                    wc.camera = camera
                    // Sync the orthographic toggle from the RESTORED camera (not the
                    // scene.camera that syncFromScene already mirrored), else the
                    // next sidebar sync re-syncs projection from a stale flag.
                    wc.state.orthographic = !camera.perspective
                    wc.setNeedsRender()
                }
            } catch {
                print("[mcrysden] failed to open \(inURL.path): \(error)")
                if isReopen {
                    // An implicit reopen of a stale/missing file must not terminate
                    // the app. Drop the broken key and open an empty viewer so the
                    // user can continue instead of getting a blank launch on every run.
                    UserDefaults.standard.removeObject(forKey: Self.lastOpenedURLKey)
                    windowRegistry.add(MainWindowController(scene: Scene()))
                } else {
                    // Explicit CLI input the user asked for: report and exit.
                    exit(EXIT_FAILURE)
                }
            }
        } else {
            windowRegistry.add(MainWindowController(scene: Scene()))
        }
    }

    /// Test-only seam: add a window to the registry without going through the
    /// full menu action. Lets controller tests assert Window-menu contents.
    internal func testAddWindow(_ wc: MainWindowController) {
        windowRegistry.add(wc)
    }

    /// File > New Window: open a fresh viewer window with an empty scene. Each
    /// window owns its own MainWindowController + scene.
    @objc func newDocument(_ sender: Any?) {
        let base = NSApp.keyWindow
        let wc = MainWindowController(scene: Scene())
        windowRegistry.add(wc)
        // Cascade new windows off the key window so they don't perfectly overlap.
        if let base {
            let f = base.frame
            wc.window.setFrame(NSRect(x: f.origin.x + 24, y: f.origin.y - 24,
                                      width: f.width, height: f.height), display: false)
        }
        wc.window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar

    func buildMenu() -> NSMenu {
        let main = NSMenu()
        // macOS reserves the first top-level item for the application menu. Keep
        // Quit there so the following item is displayed as an actual File menu.
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: "mcrysden")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit mcrysden", action: #selector(NSApp.terminate), keyEquivalent: "q")
        // File
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.delegate = self
        fileItem.submenu = file
        let openItem = file.addItem(withTitle: "Open\u{2026}", action: #selector(openDocument), keyEquivalent: "o")
        openItem.target = self
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentItem.submenu = recentMenu
        self.recentItem = recentItem
        let revertItem = file.addItem(withTitle: "Revert To Saved", action: #selector(revertToSaved), keyEquivalent: "")
        revertItem.target = self
        self.revertItem = revertItem
        let saveStateAsItem = file.addItem(withTitle: "Save State As\u{2026}", action: #selector(saveStateAs), keyEquivalent: "S")
        saveStateAsItem.target = self
        let exportItem = file.addItem(withTitle: "Export\u{2026}", action: #selector(exportDocument), keyEquivalent: "e")
        exportItem.target = self
        let exportOptionsItem = file.addItem(withTitle: "Export Options\u{2026}", action: #selector(showExportOptions), keyEquivalent: "")
        exportOptionsItem.target = self
        let newWindowItem = file.addItem(withTitle: "New Window", action: #selector(newDocument), keyEquivalent: "N")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        newWindowItem.target = self
        // Edit — must precede View in the standard macOS menu ordering.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        let undoItem = edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        undoItem.target = nil; redoItem.target = nil
        let sep1 = NSMenuItem.separator(); edit.addItem(sep1)
        let cutItem = edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        cutItem.target = nil; copyItem.target = nil; pasteItem.target = nil; selectAllItem.target = nil
        let sep2 = NSMenuItem.separator(); edit.addItem(sep2)
        let copyViewItem = edit.addItem(withTitle: "Copy Current View", action: #selector(copyCurrentView), keyEquivalent: "C")
        copyViewItem.target = self
        // Command palette
        let paletteItem = edit.addItem(withTitle: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "P")
        paletteItem.target = self
        // View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        let lbl = view.addItem(withTitle: "Toggle Element Labels", action: #selector(toggleLabelsFromMenu), keyEquivalent: "l")
        lbl.target = self
        // Window
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.delegate = self
        windowItem.submenu = windowMenu
        let minimizeItem = windowMenu.addItem(withTitle: "Minimize", action: Selector(("miniaturize:")), keyEquivalent: "m")
        minimizeItem.target = nil   // route to first responder
        let zoomItem = windowMenu.addItem(withTitle: "Zoom", action: Selector(("zoom:")), keyEquivalent: "")
        zoomItem.target = nil
        windowMenu.addItem(NSMenuItem.separator())
        let bringAllItem = windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApp.arrangeInFront(_:)), keyEquivalent: "")
        bringAllItem.target = NSApp
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

    /// File > Save State As...
    @MainActor
    @objc private func saveStateAs(_ sender: Any?) {
        guard let wc = mainWC else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "state.mvis-state"
        panel.allowedContentTypes = [Self.stateContentType]
        panel.beginSheetModal(for: wc.window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try Self.validateGUIWriteDestination(url, source: wc.currentSourceURL)
                try wc.saveState(to: url)
            } catch {
                print("[mcrysden] save state failed: \(error)")
                self.presentFileOperationError(error, title: "save state failed", for: wc)
            }
        }
    }

    /// File > Export...  Present a save panel, then render the live scene/camera
    /// to the chosen URL at a viewport-derived size. Mirrors the Open workflow:
    /// main-thread scene/camera handoff, size validation inside exportScene, and a
    /// non-fatal console error on failure.
    @MainActor
    @objc private func exportDocument(_ sender: Any?) {
        guard let wc = mainWC else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.png"
        panel.allowedContentTypes = Self.exportContentTypes
        panel.beginSheetModal(for: wc.window) { result in
            guard result == .OK, let url = panel.url else { return }
            let size = CGSize(width: self.exportOptions.width, height: self.exportOptions.height)
            do {
                try self.exportOptions.validate()
                try Self.validatedExportSize(size)
                try Self.validateGUIWriteDestination(url, source: wc.currentSourceURL)
                try wc.exportCurrentView(to: url, size: size, options: self.exportOptions)
            } catch {
                print("[mcrysden] export failed: \(error)")
                self.presentFileOperationError(error, title: "export failed", for: wc)
            }
        }
    }

    @MainActor
    private func presentFileOperationError(_ error: Error, title: String, for controller: MainWindowController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: controller.window)
    }

    /// Graphs and label overlays are defined in AppKit points, so GUI export uses
    /// the viewport's logical size. Higher-resolution output belongs to the future
    /// configurable-dimensions workflow rather than silently changing typography.
    static func exportSizeForViewport(_ viewportSize: CGSize) -> CGSize { viewportSize }

    /// Build an NSColor from a clear-color tuple. Returns nil for transparent (alpha 0).
    static func color(from clearColor: (r: Double, g: Double, b: Double, a: Double)?) -> NSColor? {
        guard let c = clearColor, c.a > 0 else { return nil }
        return NSColor(deviceRed: c.r, green: c.g, blue: c.b, alpha: c.a)
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
            self.openFile(url, into: wc)
        }
    }

    /// Shared Open path used by Open..., Open Recent, and drag-and-drop: parse
    /// `url` and load it into `wc`. Mirrors the Open panel's error handling.
    private func openFile(_ url: URL, into wc: MainWindowController? = nil) {
        let wc = wc ?? mainWC
        guard let wc else { return }
        do {
            let scene = Scene(loaded: try Parser.load(url))
            wc.loadFile(scene, from: url, format: nil, frameIndex: 0)
        } catch {
            print("[mcrysden] open failed: \(error)")
        }
    }

    /// File > Revert To Saved: re-read the loaded source and reload it, exactly
    /// as Open does. Disabled when no file is loaded (menu delegate). The
    /// controller owns sourceURL/forcedFormat, so the work happens there.
    @MainActor
    @objc private func revertToSaved(_ sender: Any?) {
        mainWC?.revertToSource()
    }

    /// File > Open Recent > <file>: open a recently-viewed document.
    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openFile(url)
    }

    /// File > Open Recent > Clear Menu: empty the recent-documents list.
    @objc private func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: - NSMenuDelegate

    /// Enable/disable Revert and rebuild Open Recent each time the File menu opens.
    /// Also rebuilds the per-window list in the Window menu.
    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        if menu.title == "File" {
        revertItem?.isEnabled = (mainWC?.currentSourceURL != nil)
        guard let recentItem else { return }
        let submenu = NSMenu(title: "Open Recent")
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = submenu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        if !NSDocumentController.shared.recentDocumentURLs.isEmpty {
            submenu.addItem(NSMenuItem.separator())
        }
        let clearItem = submenu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentDocuments(_:)), keyEquivalent: "")
        clearItem.target = self
        recentItem.submenu = submenu
        }
        if menu.title == "Window" {
            // Remove the per-window items (everything after the 4 standard items).
            while menu.items.count > 4 { menu.removeItem(at: menu.items.count - 1) }
            let windows = windowRegistry.windows
            if windows.count > 1 { menu.addItem(NSMenuItem.separator()) }
            for w in windows {
                var name = w.title
                if let url = (w.delegate as? MainWindowController)?.currentSourceURL, !url.lastPathComponent.isEmpty {
                    name = url.lastPathComponent
                }
                let item = menu.addItem(withTitle: name, action: #selector(selectWindowFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = w
                if w === (windowRegistry.active?.window) { item.state = .on }
            }
        }
    }

    @objc private func selectWindowFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? NSWindow)?.makeKeyAndOrderFront(nil)
    }

    static func supportsOpenURL(_ url: URL) -> Bool {
        url.hasDirectoryPath || ParseFormat.from(url: url) != nil
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Self.supportsOpenURL(url)
    }

    static func validateExportDestination(_ output: URL, input: URL, state: URL?) throws {
        // Pairwise: no two of {input, state, output} may alias one another
        // (canonical path, symlink target, or hardlink inode) — exporting onto
        // an input/state would corrupt the source, and an input that is the same
        // file as its state is a malformed invocation.
        if let state, sameFile(input, state) {
            throw CLIError.invalid("input and state alias the same file: \(input.path)")
        }
        for protected in [input, state].compactMap({ $0 }) where sameFile(output, protected) {
            throw CLIError.invalid("export output aliases protected input: \(protected.path)")
        }
    }

    /// GUI writes must not replace the file currently supplying the live scene.
    /// `sameFile` covers equal paths, symlinks, and existing hardlink aliases.
    static func validateGUIWriteDestination(_ output: URL, source: URL?) throws {
        guard let source, sameFile(output, source) else { return }
        throw CLIError.invalid("destination aliases loaded source: \(source.path)")
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left.path == right.path { return true }
        let fm = FileManager.default
        guard let la = try? fm.attributesOfItem(atPath: left.path),
              let ra = try? fm.attributesOfItem(atPath: right.path),
              let lfs = la[.systemNumber] as? NSNumber,
              let rfs = ra[.systemNumber] as? NSNumber,
              let lfile = la[.systemFileNumber] as? NSNumber,
              let rfile = ra[.systemFileNumber] as? NSNumber else { return false }
        return lfs == rfs && lfile == rfile
    }

    @MainActor
    @discardableResult
    static func exportScene(_ scene: Scene, camera: Camera?, to url: URL, size: CGSize,
                            options: RenderExportOptions = RenderExportOptions(),
                            exportOptions: ExportOptions? = nil) throws -> CGImage {
        // Compute the effective clear color: explicit export option wins, else derive
        // from the scene background so callers without options preserve gradients.
        // Only pass an explicit background override when export options were
        // supplied. Otherwise leave it nil so the scene's own background
        // (including gradients) is preserved for CLI/headless/clipboard exports.
        let effectiveBackground: (r: Double, g: Double, b: Double, a: Double)? =
            exportOptions?.clearColor
        guard supportedExportExtensions.contains(url.pathExtension.lowercased()) else {
            throw CLIError.invalid("unsupported export extension: \(url.pathExtension)")
        }
        // Route size through the shared validator so the DOS/band/plane graph routes
        // below never trap on an Int cast or allocate an absurd buffer; any
        // non-finite/non-positive/oversized/overflowing size throws here first.
        let _ = try validatedExportSize(size)
        // Graph/color-plane exports: EPS/PS have no alpha support.
        if exportOptions?.isTransparent == true && ["eps", "ps"].contains(url.pathExtension.lowercased()) {
            throw CLIError.invalid("transparent export is not supported for \(url.pathExtension.uppercased()); use PNG or PDF instead")
        }
        let isTransparent = exportOptions?.isTransparent ?? false
        let graphBackground = Self.color(from: effectiveBackground)
        if let dos = scene.densityOfStates {
            return try exportGraph(DOSGrapherView(frame: NSRect(origin: .zero, size: size)), configure: {
                $0.densityOfStates = dos
                $0.exportBackground = graphBackground
                $0.isExportTransparent = isTransparent
            }, to: url, size: size)
        }
        if let bands = scene.bandStructure {
            return try exportGraph(BandGrapherView(frame: NSRect(origin: .zero, size: size)), configure: {
                $0.bandStructure = bands
                $0.exportBackground = graphBackground
                $0.isExportTransparent = isTransparent
            }, to: url, size: size)
        }
        if scene.showColorPlane, let grid = scene.grid2D {
            return try exportGraph(ColorPlaneView(frame: NSRect(origin: .zero, size: size)), configure: {
                $0.grid = grid.values
                $0.physicalSpan = Array(grid.vec.prefix(2))
                $0.zLabel = grid.ident
                if grid.maxValue > grid.minValue {
                    $0.contourLevels = (1..<6).map {
                        grid.minValue + (grid.maxValue - grid.minValue) * Float($0) / 6
                    }
                }
                $0.exportBackground = graphBackground
                $0.isExportTransparent = isTransparent
            }, to: url, size: size)
        }
        switch url.pathExtension.lowercased() {
        case "pdf", "svg":
            return try RasterExporter.export(scene: scene, camera: camera, to: url, size: size, options: options,
                                              background: effectiveBackground)
        case "eps", "ps":
            // EPS/PS have no alpha support: reject transparency and flatten.
            if exportOptions?.isTransparent == true {
                throw CLIError.invalid("transparent export is not supported for \(url.pathExtension.uppercased()); use PNG or PDF instead")
            }
            return try RasterExporter.export(scene: scene, camera: camera, to: url, size: size, options: options,
                                              background: effectiveBackground)
        case "png":
            return try PngExporter.export(scene: scene, camera: camera, to: url, size: size, options: options,
                                           background: Self.color(from: effectiveBackground),
                                           transparent: exportOptions?.isTransparent ?? false)
        default:
            throw CLIError.invalid("unsupported export extension: \(url.pathExtension)")
        }
    }

    @MainActor
    static func exportGraph<View: NSView>(_ view: View, configure: (View) -> Void,
                                           to url: URL, size: CGSize,
                                           background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        let (width, height) = try validatedExportSize(size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DOSExportError.noBitmap
        }
        configure(view)
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        // Apply custom background if provided (opaque only); otherwise leave transparent.
        if let bg = background, bg.a > 0 {
            context.cgContext.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw DOSExportError.noImage }
        switch url.pathExtension.lowercased() {
        case "pdf", "svg", "eps", "ps":
            try RasterExporter.write(cgImage: image, to: url, size: size)
        case "png":
            try PngExporter.write(cgImage: image, to: url)
        default:
            // A non-pdf/svg/eps/ps/png extension must not silently write PNG bytes;
            // report the truthful unsupported-format reason (matches the outer gate).
            throw CLIError.invalid("unsupported export extension: \(url.pathExtension)")
        }
        return image
    }

    /// Edit > Copy Current View — render the live viewport scene/camera to a CGImage
    /// and place it on the general pasteboard. Momentary menu-title change is the
    /// lightweight success/failure feedback (no alert, no status bar).
    @MainActor
    @objc private func copyCurrentView(_ sender: Any?) {
        guard let wc = mainWC, let item = sender as? NSMenuItem else { return }
        let size = Self.exportSizeForViewport(wc.viewport.bounds.size)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-clip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let image = try wc.exportCurrentView(to: tmp, size: size)
            let pb = NSPasteboard.general
            pb.clearContents()
            let ok = pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
            flashCopyResult(item, success: ok)
        } catch {
            print("[mcrysden] copy current view failed: \(error)")
            flashCopyResult(item, success: false)
        }
    }

    /// Briefly change the Copy Current View menu title to confirm (or report) the
    /// copy, then restore the original after a short delay.
    func flashCopyResult(_ item: NSMenuItem, success: Bool) {
        if copyResetOriginal == nil {
            copyResetOriginal = item.title
        }
        item.title = success ? "Copied View" : "Copy Failed"
        copyResetTimer?.invalidate()
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self, weak item] _ in
            item?.title = self?.copyResetOriginal ?? item?.title ?? "Copy Current View"
            self?.copyResetTimer = nil
            self?.copyResetOriginal = nil
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
    static let appVersion = "1.3.0"

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

extension App.CLIError: LocalizedError {
    var errorDescription: String? { description }
}

extension PngExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noGPU: return "no Metal GPU is available"
        case .noTex: return "the requested export dimensions are invalid or unsupported"
        case .noCGImage: return "could not create the rendered image"
        case .noPNG: return "could not encode PNG data"
        case .noQueue, .noCommandBuffer: return "could not prepare the Metal export command"
        case .encodeFailed: return "Metal could not encode the export frame"
        case .commandBufferError(let error): return error?.localizedDescription ?? "Metal failed while rendering the export"
        }
    }
}

extension RasterExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noGPU: return "no Metal GPU is available"
        case .noTex: return "the requested export dimensions are invalid or unsupported"
        case .noCGImage: return "could not create the rendered image"
        case .noContext: return "could not create the export graphics context"
        case .noData: return "could not write export data"
        case .unsupported: return "the requested export format is unsupported"
        case .noQueue, .noCommandBuffer: return "could not prepare the Metal export command"
        case .encodeFailed: return "Metal could not encode the export frame"
        case .commandBufferError(let error): return error?.localizedDescription ?? "Metal failed while rendering the export"
        }
    }
}
