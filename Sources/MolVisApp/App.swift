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
    /// Analysis submenu reference so checkmark refresh does not depend on NSApp.
    private weak var analysisMenu: NSMenu?

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
        var kPathImportURL: URL?
        var format: ParseFormat?
        var frame = -1
        /// MSAA sample-count override. nil = flag omitted (use scene/default);
        /// 1/2/4/8 = explicit override applied in GUI and export.
        var msaaSampleCount: Int? = nil
        /// Whether --msaa was seen at all. Used to reject duplicate --msaa
        /// flags regardless of the first value.
        var msaaSeen = false
        /// Publication preset override. nil = flag omitted (use scene/default).
        var preset: PublicationPreset? = nil
        var help = false
        /// Headless single-file conversion target (--convert / --pwi2xsf / --pwo2xsf / --struct2xsf).
        var convertURL: URL?
        /// Headless batch conversion output directory (--convert-all).
        var convertAllURL: URL?
        /// Target structure format for --convert-all (--format <xsf|cif|poscar|xyz|qe|struct|d12>).
        var convertFormat: StructureExportFormat?
        /// Headless script file (--script).
        var scriptURL: URL?
        /// Headless animation export target (--export-anim).
        var exportAnimationURL: URL?
        /// Frames per second for --export-anim (default 10).
        var animFPS: Int = 10
        /// Frame count for --export-anim (--frames K): 0 = every remaining frame,
        /// >0 = at most K frames counted from the start frame (--frame N).
        var animFrameCount: Int = 0
        /// Explicit viewport size for --export-anim (--anim-size WxH).
        var animSize: CGSize?
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
        FormatInfo(flag: "--gzmat",   extensions: ["gzmat", "zmat"],             format: .gzmat),
        FormatInfo(flag: "--crystal-band", extensions: ["band", "fort9"],        format: .crystalBand),
        FormatInfo(flag: "--crystal-dos", extensions: ["doss", "fort8"],         format: .crystalDOS),
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

    /// True when the command line asks for the usage text. Checked before full
    /// parsing so `--help` short-circuits every other flag and all validation.
    /// `--` still terminates option parsing, matching `parseArguments`.
    static func requestsHelp(_ args: [String]) -> Bool {
        for argument in args {
            if argument == "--" { return false }
            if argument == "--help" || argument == "-h" { return true }
        }
        return false
    }

    static func parseArguments(_ args: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var positionals: [String] = []
        var forced: ParseFormat?
        var index = 0
        var optionsEnded = false
        var convertVerbSeen = false
        var convertRequiresXSF = false
        var fpsSeen = false
        var framesSeen = false
        var animSizeSeen = false
        while index < args.count {
            let argument = args[index]
            if !optionsEnded && argument == "--" {
                optionsEnded = true
            } else if !optionsEnded && (argument == "--help" || argument == "-h") {
                // --help short-circuits: return immediately so no later flag and
                // none of the post-loop consistency checks can turn a request for
                // the usage text into an error exit.
                options.help = true
                return options
            } else if !optionsEnded && argument == "--convert" {
                guard !convertVerbSeen, options.convertURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--convert requires exactly one output path")
                }
                convertVerbSeen = true
                index += 1
                options.convertURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--convert-all" {
                guard options.convertAllURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--convert-all requires exactly one output directory")
                }
                index += 1
                options.convertAllURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--format" {
                guard options.convertFormat == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--"),
                      let fmt = parseConvertFormat(args[index + 1]) else {
                    throw CLIError.invalid("--format requires one of: " + convertFormatFlags.joined(separator: ", "))
                }
                index += 1
                options.convertFormat = fmt
            } else if !optionsEnded && argument == "--script" {
                guard options.scriptURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--script requires exactly one file path")
                }
                index += 1
                options.scriptURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--export-anim" {
                guard options.exportAnimationURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--export-anim requires exactly one output path")
                }
                index += 1
                options.exportAnimationURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--fps" {
                guard !fpsSeen, index + 1 < args.count,
                      let value = Int(args[index + 1]), value >= 1, value <= 600 else {
                    throw CLIError.invalid("--fps requires an integer in 1...600")
                }
                fpsSeen = true
                index += 1
                options.animFPS = value
            } else if !optionsEnded && argument == "--frames" {
                // 0 = every remaining frame (the default); >0 = at most K frames.
                guard !framesSeen, index + 1 < args.count,
                      let value = Int(args[index + 1]), value >= 0, value <= Int(Int32.max) else {
                    throw CLIError.invalid("--frames requires a non-negative 32-bit integer")
                }
                framesSeen = true
                index += 1
                options.animFrameCount = value
            } else if !optionsEnded && argument == "--anim-size" {
                guard !animSizeSeen, index + 1 < args.count,
                      let size = parseAnimSize(args[index + 1]) else {
                    throw CLIError.invalid("--anim-size requires WxH (e.g. 640x480)")
                }
                animSizeSeen = true
                index += 1
                options.animSize = size
            } else if !optionsEnded && argument == "--pwi2xsf" {
                guard !convertVerbSeen, options.convertURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--pwi2xsf requires exactly one .xsf output path")
                }
                convertVerbSeen = true
                index += 1
                options.convertURL = URL(fileURLWithPath: args[index])
                guard forced == nil else { throw CLIError.invalid("multiple force-format flags are not allowed") }
                forced = .pwi
                convertRequiresXSF = true
            } else if !optionsEnded && argument == "--pwo2xsf" {
                guard !convertVerbSeen, options.convertURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--pwo2xsf requires exactly one .xsf output path")
                }
                convertVerbSeen = true
                index += 1
                options.convertURL = URL(fileURLWithPath: args[index])
                guard forced == nil else { throw CLIError.invalid("multiple force-format flags are not allowed") }
                forced = .pwo
                convertRequiresXSF = true
            } else if !optionsEnded && argument == "--struct2xsf" {
                guard !convertVerbSeen, options.convertURL == nil,
                      index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--struct2xsf requires exactly one .xsf output path")
                }
                convertVerbSeen = true
                index += 1
                options.convertURL = URL(fileURLWithPath: args[index])
                guard forced == nil else { throw CLIError.invalid("multiple force-format flags are not allowed") }
                forced = .struct_
                convertRequiresXSF = true
            } else if !optionsEnded && argument == "--export" {
                guard options.exportURL == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--export requires exactly one output path")
                }
                index += 1
                options.exportURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--kpath" {
                guard options.kPathImportURL == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("--kpath requires exactly one file path")
                }
                index += 1
                options.kPathImportURL = URL(fileURLWithPath: args[index])
            } else if !optionsEnded && argument == "--frame" {
                guard options.frame == -1, index + 1 < args.count,
                      let frame = Int(args[index + 1]), frame >= 0, frame <= Int(Int32.max) else {
                    throw CLIError.invalid("--frame requires one non-negative 32-bit integer")
                }
                index += 1
                options.frame = frame
            } else if !optionsEnded && argument == "--msaa" {
                // A separate seen flag tracks duplicates: --msaa is now always stored
                // (1 is an explicit Off override), so msaaSeen still guards repeats.
                guard !options.msaaSeen, index + 1 < args.count,
                      let value = Int(args[index + 1]), [1, 2, 4, 8].contains(value) else {
                    throw CLIError.invalid("--msaa requires a value of 1, 2, 4, or 8")
                }
                options.msaaSeen = true
                index += 1
                // 1 is an explicit Off override: store it so it overrides a scene
                // default (e.g. 4x from a loaded state). nil means the flag was omitted.
                options.msaaSampleCount = value
            } else if !optionsEnded && argument == "--preset" {
                guard options.preset == nil, index + 1 < args.count,
                      let preset = PublicationPreset(rawValue: args[index + 1]) else {
                    throw CLIError.invalid("--preset requires one of: " + PublicationPreset.allCases.map { $0.rawValue }.joined(separator: ", "))
                }
                index += 1
                options.preset = preset
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
        if let kpathURL = options.kPathImportURL {
            guard options.inputURL != nil else { throw CLIError.invalid("a structure file is required to import a k-path") }
            for protected in [options.inputURL, options.stateURL].compactMap({ $0 }) where sameFile(kpathURL, protected) {
                throw CLIError.invalid("--kpath file aliases the input or state file: \(protected.path)")
            }
        }
        // Single action per invocation: --export, --convert, --convert-all, --script
        // and --export-anim are mutually exclusive.
        let actionCount = [options.exportURL, options.convertURL, options.convertAllURL,
                           options.scriptURL, options.exportAnimationURL].compactMap { $0 }.count
        guard actionCount <= 1 else {
            throw CLIError.invalid("only one of --export, --convert, --convert-all, --script, --export-anim may be used at once")
        }
        if let convertURL = options.convertURL {
            guard options.inputURL != nil else { throw CLIError.invalid("--convert requires an input file") }
            // `--format` names an OUTPUT structure format
            // (xsf|cif|poscar|xyz|qe|struct|d12),
            // and single-file `--convert` already derives its output format from
            // the output extension -- so the flag has nothing left to select and
            // was previously dropped in silence. It is now accepted only when it
            // agrees with the extension; a contradiction such as
            // `--convert out.cif --format xsf` names two different targets and is
            // rejected instead of quietly writing one of them. (The INPUT parser is
            // chosen by the force-format flags --xsf/--pwi/..., which --convert
            // already honors through `options.format`.)
            if let requested = options.convertFormat {
                guard let fromExtension = Converter.outputFormat(forExtension: convertURL.pathExtension) else {
                    throw CLIError.invalid("unsupported --convert output extension: \(convertURL.pathExtension)")
                }
                guard fromExtension == requested else {
                    throw CLIError.invalid("--format \(convertFormatName(requested)) conflicts with the --convert output "
                                           + "extension .\(convertURL.pathExtension.lowercased()) "
                                           + "(\(convertFormatName(fromExtension))); --format selects the output format "
                                           + "for --convert-all only")
                }
            }
            if convertRequiresXSF {
                guard convertURL.pathExtension.lowercased() == "xsf" else {
                    throw CLIError.invalid("--pwi2xsf/--pwo2xsf/--struct2xsf require an .xsf output path")
                }
            }
            for protected in [options.inputURL, options.stateURL].compactMap({ $0 }) where sameFile(convertURL, protected) {
                throw CLIError.invalid("--convert output aliases the input or state file: \(protected.path)")
            }
        }
        if let convertAllURL = options.convertAllURL {
            guard options.inputURL != nil else { throw CLIError.invalid("--convert-all requires an input directory as the positional argument") }
            guard options.convertFormat != nil else {
                throw CLIError.invalid("--convert-all requires --format <\(convertFormatFlags.joined(separator: "|"))>")
            }
            for protected in [options.inputURL, options.stateURL].compactMap({ $0 }) where sameFile(convertAllURL, protected) {
                throw CLIError.invalid("--convert-all output directory aliases the input: \(protected.path)")
            }
        }
        if let animURL = options.exportAnimationURL {
            guard options.inputURL != nil else { throw CLIError.invalid("--export-anim requires an input file") }
            guard ["gif", "apng", "mp4"].contains(animURL.pathExtension.lowercased()) else {
                throw CLIError.invalid("--export-anim requires a .gif, .apng, or .mp4 output path")
            }
        } else {
            // Animation qualifiers only bound the animation loop; anywhere else
            // they would be accepted and silently ignored, the exact class of bug
            // these checks exist to prevent.
            if framesSeen { throw CLIError.invalid("--frames requires --export-anim") }
            if fpsSeen { throw CLIError.invalid("--fps requires --export-anim") }
            if animSizeSeen { throw CLIError.invalid("--anim-size requires --export-anim") }
        }
        // `--format` names an OUTPUT structure format and only selects one for
        // `--convert`/`--convert-all`; with any other action it is meaningless
        // and must not be silently dropped.
        if options.convertFormat != nil, options.convertURL == nil, options.convertAllURL == nil {
            throw CLIError.invalid("--format requires --convert or --convert-all")
        }
        return options
    }

    /// Maps the `--format <xsf|cif|poscar|xyz|qe>` value to a structure format.
    private static func parseConvertFormat(_ raw: String) -> StructureExportFormat? {
        switch raw.lowercased() {
        case "xsf": return .xsf
        case "cif": return .cif
        case "poscar": return .poscar
        case "xyz": return .xyz
        case "qe": return .qeInput
        case "struct": return .wienStruct
        case "d12", "crystal": return .crystal03
        default: return nil
        }
    }
    private static let convertFormatFlags = ["xsf", "cif", "poscar", "xyz", "qe", "struct", "d12"]

    /// Inverse of `parseConvertFormat`, so a diagnostic names the same spelling
    /// the user typed on the command line.
    private static func convertFormatName(_ format: StructureExportFormat) -> String {
        switch format {
        case .xsf: return "xsf"
        case .cif: return "cif"
        case .poscar: return "poscar"
        case .xyz: return "xyz"
        case .qeInput: return "qe"
        case .wienStruct: return "struct"
        case .crystal95, .crystal98, .crystal03, .crystalNew: return "d12"
        }
    }

    /// Parse a `--anim-size WxH` value into a CGSize. Returns nil on any malformed input.
    private static func parseAnimSize(_ raw: String) -> CGSize? {
        let parts = raw.lowercased().split(separator: "x").map(String.init)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
            return nil
        }
        guard w <= AnimationExporter.maxDimension, h <= AnimationExporter.maxDimension else {
            return nil
        }
        let pixels = w.multipliedReportingOverflow(by: h)
        guard !pixels.overflow, pixels.partialValue <= AnimationExporter.maxTotalPixels else {
            return nil
        }
        return CGSize(width: w, height: h)
    }

    /// The frame range exported by `--export-anim`.
    ///
    /// `--frame N` is the 0-based STARTING frame (default 0) and `--frames K`
    /// bounds how many frames follow it (0 = every remaining frame). Both flags
    /// were previously parsed and then dropped by the animation path, which
    /// always exported the whole file from frame 0. An out-of-range start throws
    /// rather than exporting something the user did not ask for.
    static func animationFrameRange(total: Int, startFrame: Int, frameCount: Int,
                                    name: String) throws -> Range<Int> {
        guard total > 0 else { throw CLIError.invalid("\(name) contains no frames") }
        let start = startFrame < 0 ? 0 : startFrame
        guard start < total else {
            throw CLIError.invalid("--frame \(start) is out of range for \(name) (\(total) frame(s))")
        }
        let remaining = total - start
        let count = frameCount > 0 ? min(frameCount, remaining) : remaining
        guard count <= AnimationExporter.maxFrameCount else {
            throw CLIError.invalid("animation frame count exceeds the cap of \(AnimationExporter.maxFrameCount)")
        }
        return start..<(start + count)
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
    static func loadScene(
        from url: URL,
        format: ParseFormat?,
        cliFrame: Int,
        stateURL: URL?,
        kPathImportURL: URL? = nil,
        kPathSampling: inout Int
    ) throws -> (scene: Scene, camera: Camera?, cameraBookmarks: [CameraBookmark?]) {
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
        var cameraBookmarks = Array<CameraBookmark?>(
            repeating: nil,
            count: CameraBookmark.slotCount
        )
        if let stateURL {
            kPathSampling = try StateStore.load(
                into: &scene,
                camera: &camera,
                cameraBookmarks: &cameraBookmarks,
                from: stateURL
            )
        }
        // Resolve the displayed frame (clamp a saved frame + reparse it) via the shared
        // helper so the GUI path and the frame-state tests run IDENTICAL logic.
        try resolveAnimationFrame(scene: &scene, from: url, format: format,
                                  loadedFrame: loadedFrame, fc: fc)
        // A --kpath import wins over any route restored from a companion state file,
        // so apply it last (after the state's route has been carried onto the scene).
        if let kPathImportURL {
            try applyKPathImport(to: &scene, from: kPathImportURL, kPathSampling: &kPathSampling)
        }
        return (scene, camera, cameraBookmarks)
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
            // Carry over every appearance/display/quality setting the user can
            // control in the sidebar (kept while only geometry changes). This
            // replaces the per-field list that previously dropped showBondDistances,
            // isoSurfaces, clipPlane, colorPlane*, volumeSlices, msaa, opacity,
            // lineWidth, depth/shadow/AO strength and quality, hbond/molecular-
            // surface settings, color scheme, element overrides, repetition mode,
            // cell rods, unicolor bonds, tessellation and anaglyph mode.
            scene.adoptAppearance(from: restored)
            // measurementMode is not an appearance field; carry it explicitly.
            scene.measurementMode = restored.measurementMode
            // The freshly parsed frame may carry a scalar field whose value range differs
            // from the frame we carried the level over (e.g. animated XSF). Clamp the
            // carried level into the new field's range so it stays meaningful; when the
            // level already fits, its value passes through unchanged. With a no-field
            // frame the level is inert (the renderer gates on scalarField), so leave it
            // untouched. Mirrors the reloadFrame clamp in MainWindowController.
            if let field = scene.scalarField {
                scene.isoLevel = min(field.maxValue, max(field.minValue, scene.isoLevel))
            }
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

    /// Apply a --kpath import to a freshly-loaded scene. The imported route is marked
    /// user-edited (signature cleared) so it is never auto-regenerated. The flag wins
    /// over any route restored from a companion state file because this runs AFTER the
    /// state is applied.
    static func applyKPathImport(to scene: inout Scene, from url: URL, kPathSampling: inout Int) throws {
        guard scene.cell != nil else { throw CLIError.invalid("--kpath \(url.path) requires a crystal structure") }
        let imported = try KPathImport.importKPath(from: url)
        scene.kPathPoints = imported.path.points
        scene.kPathBreaks = imported.path.breaks
        scene.kPathProvenance = .userEdited
        scene.kPathSignature = nil
        // Only VASP carries an explicit sampling density; QE/Wannier90/KPF
        // synthesize the default of 20, so importing them must not clobber a
        // sampling preference restored from state or set by the user.
        if imported.format == .vasp {
            kPathSampling = min(200, max(2, imported.path.pointsPerSegment))
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
        guard let window = note.object as? NSWindow,
              let wc = window.delegate as? MainWindowController,
              window === wc.window else { return }
        windowRegistry.remove(wc)
        updateAnalysisCheckmarks()
    }

    @objc func windowDidBecomeKey(_ note: Notification) {
        if let wc = (note.object as? NSWindow)?.delegate as? MainWindowController {
            windowRegistry.makeActive(wc)
            updateAnalysisCheckmarks()
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
        // --help short-circuits BEFORE parsing: asking for the usage text must
        // never be turned into an error exit by an unrelated malformed flag on
        // the same command line, and must never fall through to a headless
        // action. Exit 0 directly so `mcrysden --help` is usable in scripts.
        if Self.requestsHelp(args) {
            Self.printHelp()
            exit(EXIT_SUCCESS)
        }
        let options: LaunchOptions
        do {
            options = try Self.parseArguments(args)
        } catch {
            print("[mcrysden] \(error)")
            exit(EXIT_FAILURE)
        }
        if options.help {
            Self.printHelp()
            exit(EXIT_SUCCESS)
        }
        // headless export path
        if let outURL = options.exportURL, let inURL = options.inputURL {
            do {
                try Self.validateExportDestination(outURL, input: inURL, state: options.stateURL)
                var kPathSampling = 20
                var (scene, camera, _) = try Self.loadScene(
                    from: inURL,
                    format: options.format,
                    cliFrame: options.frame,
                    stateURL: options.stateURL,
                    kPathImportURL: options.kPathImportURL,
                    kPathSampling: &kPathSampling
                )
                let exportSize = CGSize(width: 800, height: 800)
                // Apply a --preset override to the scene's rendering quality.
                if let preset = options.preset {
                    preset.apply(to: &scene)
                }
                // Carry the explicit --msaa override into the export's render options so
                // it applies to the exported image without mutating the document scene.
                // nil (flag omitted) leaves the scene default; any value (including 1)
                // forces that sample count.
                let renderOptions = RenderExportOptions(msaaSampleCount: options.msaaSampleCount)
                try Self.exportScene(scene, camera: camera, to: outURL, size: exportSize,
                                     options: renderOptions)
            } catch {
                print("[mcrysden] export failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // headless single-file conversion (--convert / --pwi2xsf / --pwo2xsf / --struct2xsf).
        if let outURL = options.convertURL, let inURL = options.inputURL {
            do {
                try Converter.convert(url: inURL, to: outURL, forcedFormat: options.format,
                                      frameIndex: options.frame >= 0 ? options.frame : 0)
            } catch {
                print("[mcrysden] convert failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // headless batch conversion (--convert-all).
        if let outDir = options.convertAllURL, let inURL = options.inputURL {
            do {
                let count = try Converter.convertAll(
                    inputDirectory: inURL,
                    outputDirectory: outDir,
                    targetFormat: options.convertFormat ?? .xsf,
                    forcedFormat: options.format
                )
                print("[mcrysden] converted \(count) file(s) to \(outDir.path)")
            } catch {
                print("[mcrysden] convert-all failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // headless animation export (--export-anim).
        if let animURL = options.exportAnimationURL, let inURL = options.inputURL {
            do {
                try Self.validateExportDestination(animURL, input: inURL, state: options.stateURL)
                // Load the reference frame ONCE with the companion state applied:
                // this restores appearance, supercell, slab, the saved camera and
                // the saved animation frame. Each exported frame is then re-parsed
                // and re-dressed with these structural/appearance settings so the
                // animation reflects what the user saved, not raw parser defaults.
                var kPathSampling = 20
                let (refScene, refCamera, _) = try Self.loadScene(
                    from: inURL,
                    format: options.format,
                    cliFrame: options.frame,
                    stateURL: options.stateURL,
                    kPathImportURL: options.kPathImportURL,
                    kPathSampling: &kPathSampling
                )
                let fc = Parser.frameCount(inURL, as: options.format)
                let total = fc > 0 ? fc : 1
                // --frame N is the starting frame and --frames K bounds the count;
                // a state-restored currentFrame overrides --frame when none was given.
                let start = options.frame >= 0 ? options.frame : refScene.currentFrame
                let range = try Self.animationFrameRange(total: total,
                                                         startFrame: start,
                                                         frameCount: options.animFrameCount,
                                                         name: inURL.lastPathComponent)
                var scenes: [Scene] = []
                scenes.reserveCapacity(range.count)
                for i in range {
                    var scene = Scene(loaded: try Parser.load(inURL, as: options.format, frameIndex: i))
                    if refScene.superCell.total > 1 { scene = scene.widenSuperCell(refScene.superCell) }
                    if let slab = refScene.slab { scene = scene.applySlab(slab) }
                    scene.adoptAppearance(from: refScene)
                    if let preset = options.preset { preset.apply(to: &scene) }
                    if let msaa = options.msaaSampleCount { scene.msaaSampleCount = msaa }
                    scenes.append(scene)
                }
                let size = options.animSize ?? CGSize(width: 640, height: 480)
                let ext = animURL.pathExtension.lowercased()
                let aformat: AnimationExportFormat = ext == "gif" ? .gif : (ext == "mp4" ? .mp4 : .apng)
                try AnimationExporter.export(frames: scenes, camera: refCamera, size: size, fps: options.animFPS,
                                             format: aformat, to: animURL)
            } catch {
                print("[mcrysden] export-anim failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // headless script (--script).
        if let scriptURL = options.scriptURL {
            do {
                let content = try readCappedText(scriptURL, cap: 16 * 1024 * 1024)
                let workingDirectory = scriptURL.deletingLastPathComponent()
                // Shared with ScriptRunner so `~`/`$HOME`, absolute, and
                // script-relative paths resolve identically everywhere.
                func resolve(_ arg: String) -> URL {
                    ScriptRunner.resolvePath(arg, workingDirectory: workingDirectory)
                }
                final class Holder<T> { var value: T?; init() {} }
                let currentScene = Holder<Scene>()
                var commands: [String: ([String]) throws -> String] = [:]

                commands["echo"] = { args in
                    args.joined(separator: " ")
                }

                commands["convert"] = { args in
                    guard args.count == 2 else {
                        throw CLIError.invalid("convert requires <input> <output>")
                    }
                    let inURL = resolve(args[0])
                    let outURL = resolve(args[1])
                    guard !App.sameFile(inURL, outURL) else {
                        throw CLIError.invalid("output aliases input")
                    }
                    try Converter.convert(url: inURL, to: outURL, forcedFormat: nil)
                    return "converted \(inURL.path) -> \(outURL.path)"
                }

                commands["export-anim"] = { args in
                    guard args.count == 2 || args.count == 3 else {
                        throw CLIError.invalid("export-anim requires <input> <output> [fps]")
                    }
                    let inURL = resolve(args[0])
                    let outURL = resolve(args[1])
                    let fps = args.count == 3 ? (Int(args[2]) ?? -1) : 10
                    guard (1...600).contains(fps) else {
                        throw CLIError.invalid("export-anim fps must be in 1...600")
                    }
                    guard !App.sameFile(inURL, outURL) else {
                        throw CLIError.invalid("output aliases input")
                    }
                    let fc = Parser.frameCount(inURL, as: nil)
                    let total = fc > 0 ? fc : 1
                    let range = try App.animationFrameRange(total: total, startFrame: 0,
                                                            frameCount: 0,
                                                            name: inURL.lastPathComponent)
                    var scenes: [Scene] = []
                    scenes.reserveCapacity(range.count)
                    for i in range {
                        scenes.append(Scene(loaded: try Parser.load(inURL, as: nil, frameIndex: i)))
                    }
                    let ext = outURL.pathExtension.lowercased()
                    guard let format = AnimationExportFormat(rawValue: ext) else {
                        throw CLIError.invalid("unsupported animation format: \(ext)")
                    }
                    try AnimationExporter.export(frames: scenes, camera: nil,
                                                 size: CGSize(width: 640, height: 480),
                                                 fps: fps, format: format, to: outURL)
                    return "exported animation -> \(outURL.path)"
                }

                commands["load"] = { args in
                    guard args.count == 1 else {
                        throw CLIError.invalid("load requires <input>")
                    }
                    let scene = Scene(loaded: try Parser.load(resolve(args[0]), as: nil))
                    currentScene.value = scene
                    return "loaded \(args[0])"
                }

                commands["project-save"] = { args in
                    guard args.count == 1 else {
                        throw CLIError.invalid("project-save requires <output>")
                    }
                    guard let scene = currentScene.value else {
                        throw CLIError.invalid("project-save requires a loaded scene (run load first)")
                    }
                    let outURL = resolve(args[0])
                    // TODO: alias guard needs source URL
                    try ProjectStore.save(scene, to: outURL)
                    return "saved project -> \(outURL.path)"
                }

                commands["project-load"] = { args in
                    guard args.count == 1 else {
                        throw CLIError.invalid("project-load requires <input>")
                    }
                    let scene = try ProjectStore.load(from: resolve(args[0]))
                    currentScene.value = scene
                    return "loaded project \(args[0])"
                }

                commands["plugins"] = { args in
                    if args.count == 1 {
                        currentScene.value = Scene(loaded: try Parser.load(resolve(args[0]), as: nil))
                    }
                    var out = PluginRegistry.listText()
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                    if let scene = currentScene.value {
                        for (name, output) in PluginRegistry.runAll(scene: scene) {
                            out.append("\(name): \(output ?? "<unavailable>")")
                        }
                    }
                    return out.joined(separator: "\n")
                }

                let ctx = ScriptContext(
                    workingDirectory: workingDirectory,
                    onOutput: { print($0) },
                    commands: commands
                )
                try ScriptRunner.run(script: content, context: ctx)
            } catch {
                print("[mcrysden] script failed: \(error)")
                exit(EXIT_FAILURE)
            }
            NSApp.terminate(nil)
            return
        }
        // GUI path. Resolve which file to open: explicit CLI input always wins;
        // otherwise fall back to the stored lastOpenedURL (implicit reopen).
        // An `odoc` open event is delivered BEFORE this method, so when Finder
        // already handed us documents, do not additionally reopen the stored
        // lastOpenedURL (or add an empty window) on top of them.
        if didOpenFilesFromSystem, options.inputURL == nil { return }
        let (inputURL, isReopen) = Self.resolveLaunchURL(options: options)
        if let inURL = inputURL {
            do {
                // loadScene honors a saved animation frame by re-parsing it (the
                // saved frame becomes geometry, not just metadata).
                var kPathSampling = 20
                var (scene, camera, cameraBookmarks) = try Self.loadScene(
                    from: inURL,
                    format: options.format,
                    cliFrame: options.frame,
                    stateURL: options.stateURL,
                    kPathImportURL: options.kPathImportURL,
                    kPathSampling: &kPathSampling
                )
                // Apply a --msaa override to the document scene in GUI mode. The
                // sidebar picker (Appearance > MSAA) writes the same field, so a CLI
                // override simply sets the initial value the user would otherwise pick
                // by hand. All explicit values (including 1 = Off) override a loaded
                // state's setting; nil (flag omitted) leaves the scene default intact.
                if let msaa = options.msaaSampleCount {
                    scene.msaaSampleCount = msaa
                }
                // Apply a --preset override to the scene's rendering quality.
                if let preset = options.preset {
                    preset.apply(to: &scene)
                }
                let wc = MainWindowController(scene: Scene())
                windowRegistry.add(wc)
                wc.loadFile(
                    scene,
                    from: inURL,
                    format: options.format,
                    frameIndex: scene.currentFrame,
                    cameraBookmarks: cameraBookmarks
                )
                // kPathSampling is a UI-only preference, not a scene field, so it is not
                // restored by syncFromScene; apply the value decoded from state here.
                wc.state.kPathSampling = kPathSampling
                if let camera {
                    wc.camera = camera
                    wc.scene.camera = camera
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
        let exportStructureItem = file.addItem(withTitle: "Export Structure\u{2026}", action: #selector(exportStructureDocument), keyEquivalent: "")
        exportStructureItem.target = self
        let saveScriptItem = file.addItem(withTitle: "Save XCrySDen Script\u{2026}", action: #selector(MainWindowController.saveXcrysdenScript(_:)), keyEquivalent: "")
        saveScriptItem.target = nil
        let exportOptionsItem = file.addItem(withTitle: "Export Options\u{2026}", action: #selector(showExportOptions), keyEquivalent: "")
        exportOptionsItem.target = self
        let newWindowItem = file.addItem(withTitle: "New Window", action: #selector(newDocument), keyEquivalent: "N")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        newWindowItem.target = self
        // File > Print… (Cmd-P) reaches the key window's controller through the
        // responder chain (target nil); MainWindowController.printDocument handles
        // the currently visible layer (Metal scene or graph).
        let printItem = file.addItem(withTitle: "Print\u{2026}", action: #selector(MainWindowController.printDocument(_:)), keyEquivalent: "p")
        printItem.target = nil
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
        analysis.delegate = self
        analysisItem.submenu = analysis
        self.analysisMenu = analysis
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

    /// File > Export Structure…  Choose a format from an accessory popup, then
    /// write the structure through the controller's direct-write path.
    @MainActor
    @objc private func exportStructureDocument(_ sender: Any?) {
        guard let wc = mainWC else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "structure.xsf"
        panel.canCreateDirectories = true

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 25), pullsDown: false)
        for format in StructureExportFormat.allCases {
            popup.addItem(withTitle: format.label)
            popup.lastItem?.representedObject = format
            if format == .xsf { popup.select(popup.lastItem) }
        }
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 0, y: 12, width: 50, height: 20)
        popup.frame = NSRect(x: 56, y: 10, width: 190, height: 25)
        accessory.addSubview(label)
        accessory.addSubview(popup)
        panel.accessoryView = accessory

        panel.beginSheetModal(for: wc.window) { result in
            guard result == .OK, let url = panel.url else { return }
            let format = popup.selectedItem?.representedObject as? StructureExportFormat ?? .xsf
            wc.exportStructure(format, to: url)
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
    @MainActor
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

    /// Shared Open path used by Open..., Open Recent, Finder open events, and
    /// drag-and-drop: parse `url` and load it into `wc`. A parse failure is now
    /// surfaced in an alert on the target window as well as logged: the Finder
    /// path has no console for the user to read, and a window that silently did
    /// not change is indistinguishable from a hang.
    @MainActor
    @discardableResult
    private func openFile(_ url: URL, into wc: MainWindowController? = nil) -> Bool {
        let wc = wc ?? mainWC
        guard let wc else { return false }
        // XCrySDen view scripts (.tcl) apply to the LIVE window instead of
        // replacing its document: the script carries only view state.
        if url.pathExtension.lowercased() == "tcl" {
            wc.loadXcrydenScript(url)
            return true
        }
        do {
            let scene = Scene(loaded: try Parser.load(url))
            wc.loadFile(scene, from: url, format: nil, frameIndex: 0)
            return true
        } catch {
            print("[mcrysden] open failed: \(error)")
            presentFileOperationError(error, title: "Could not open \(url.lastPathComponent)", for: wc)
            return false
        }
    }

    // MARK: - Finder / open-app events

    /// True once an `odoc` open event has been serviced. `openFiles:` is
    /// delivered BEFORE applicationDidFinishLaunching, so the launch path must
    /// not additionally reopen the stored lastOpenedURL on top of the document
    /// the user just double-clicked.
    private var didOpenFilesFromSystem = false

    /// Finder double-click, `open -a mcrysden file.xyz`, and drops on the app
    /// icon all arrive as an `odoc` Apple event routed here. Without this method
    /// the event is answered by AppKit's default no-op and the file is silently
    /// never opened.
    ///
    /// Each file goes through the SAME `openFile` path the Open... menu item
    /// uses, so format sniffing, recent-documents bookkeeping, file watching and
    /// error reporting are identical. CLI-only options (`--frame`, the
    /// force-format flags) deliberately do not apply here: an open event carries
    /// nothing but a path.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit also turns plain command-line file arguments into an `odoc`
        // event. Those paths are already owned by `parseArguments` (which may
        // pair them with --frame/a force-format flag, or run a headless action
        // and exit), so opening them again here would double-load the document
        // -- and would pop a GUI window in the middle of a headless export.
        // Anything present in our own argv is therefore CLI-owned and skipped.
        // Compare by resolved file identity rather than raw string equality: a
        // path passed on the command line (e.g. `./data.xyz`) and the same
        // document re-delivered as an `odoc` event are absolutized and symlink-
        // resolved by AppKit to `/abs/.../data.xyz` -- equal files but unequal
        // strings, so a `Set<String>.contains` check lets the document open
        // TWICE. `sameFile` collapses path, symlink-target and hardlink aliases;
        // genuinely distinct files (several documents dropped at once) still
        // open in separate windows. Dedupe the delivered filenames among
        // themselves too, so a double-delivered path opens only once.
        let cliURLs = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        var seenSystem: [URL] = []
        let systemFiles = filenames.filter { path in
            let candidate = URL(fileURLWithPath: path)
            if cliURLs.contains(where: { Self.sameFile(candidate, $0) }) { return false }
            if seenSystem.contains(where: { Self.sameFile(candidate, $0) }) { return false }
            seenSystem.append(candidate)
            return true
        }
        guard !systemFiles.isEmpty else {
            // Nothing left for us to open (empty event, or every path is CLI
            // owned) -- still answer so the sender is not left waiting for a
            // reply that never comes.
            sender.reply(toOpenOrPrint: .success)
            return
        }
        didOpenFilesFromSystem = true
        var failed = false
        for path in systemFiles {
            if !openFileFromSystem(URL(fileURLWithPath: path)) { failed = true }
        }
        sender.reply(toOpenOrPrint: failed ? .failure : .success)
    }

    /// Clicking the Dock icon with no visible window must restore a usable
    /// viewer: raise an existing window, reopen the last document through the
    /// shared open path, or present an empty window. Returning false tells
    /// AppKit the reopen was handled here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        if let existing = windowRegistry.active {
            existing.window.makeKeyAndOrderFront(nil)
            return false
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastOpenedURLKey),
           !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            openFileFromSystem(URL(fileURLWithPath: path))
            return false
        }
        makeViewerWindow().window.makeKeyAndOrderFront(nil)
        return false
    }

    /// Open `url` in a reusable empty viewer window when there is one, else in a
    /// new window. Returns false when the file could not be parsed (the alert has
    /// already been presented by `openFile`).
    @MainActor
    @discardableResult
    private func openFileFromSystem(_ url: URL) -> Bool {
        let target = reusableEmptyWindow() ?? makeViewerWindow()
        let ok = openFile(url, into: target)
        target.window.makeKeyAndOrderFront(nil)
        return ok
    }

    /// An already-open window holding no document, reused instead of stacking a
    /// second window on top of the empty one opened at launch.
    @MainActor
    private func reusableEmptyWindow() -> MainWindowController? {
        windowRegistry.windows
            .compactMap { $0.delegate as? MainWindowController }
            .first { $0.currentSourceURL == nil && $0.scene.atoms.isEmpty }
    }

    /// Create and register a viewer window, cascaded off the key window so a
    /// multi-file open event does not stack windows exactly on top of each other.
    /// Mirrors `newDocument`'s placement.
    @MainActor
    @discardableResult
    private func makeViewerWindow() -> MainWindowController {
        let base = NSApp?.keyWindow ?? windowRegistry.windows.last
        let wc = MainWindowController(scene: Scene())
        windowRegistry.add(wc)
        if let base {
            let f = base.frame
            wc.window.setFrame(NSRect(x: f.origin.x + 24, y: f.origin.y - 24,
                                      width: f.width, height: f.height), display: false)
        }
        return wc
    }

    /// File > Revert To Saved: re-read the loaded source and reload it, exactly
    /// as Open does. Disabled when no file is loaded (menu delegate). The
    /// controller owns sourceURL/forcedFormat, so the work happens there.
    @MainActor
    @objc private func revertToSaved(_ sender: Any?) {
        mainWC?.revertToSource()
    }

    /// File > Open Recent > <file>: open a recently-viewed document.
    @MainActor
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
    /// Also rebuilds the per-window list in the Window menu and refreshes the
    /// Analysis checkmarks so they always reflect the active viewer's mode.
    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        if menu.title == "Analysis" {
            updateAnalysisCheckmarks()
        }
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

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
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
        // Derive effective render options so the export panel's MSAA picker actually
        // reaches the renderer. An explicit exportOptions.msaaSampleCount override
        // (including 1 = force Off) wins; when nil (Use Document) we preserve the
        // incoming options.msaaSampleCount so the scene's own value — or a CLI
        // --msaa override already baked into options — still applies. Without this,
        // the export panel's MSAA selection is silently dropped on the render path.
        var effectiveOptions = options
        if let msaa = exportOptions?.msaaSampleCount {
            effectiveOptions.msaaSampleCount = msaa
        }
        if let dos = scene.densityOfStates, let bands = scene.bandStructure {
            // Both present: one side-by-side image containing both panels. exportGraph
            // routes PDF through writeGraphVectorPDF (true vector for both graphs) and
            // raster-backed SVG/EPS/PS/PNG through the bitmap branch.
            return try exportGraph(
                LinkedGraphsView(frame: NSRect(origin: .zero, size: size),
                                bandView: BandGrapherView(frame: .zero),
                                dosView: DOSGrapherView(frame: .zero),
                                band: bands, dos: dos, bandPresent: true, dosPresent: true),
                configure: {
                    $0.exportBackground = graphBackground
                    $0.isExportTransparent = isTransparent
                }, to: url, size: size)
        }
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
            return try TrueVectorExporter.export(scene: scene, camera: camera, to: url, size: size, options: effectiveOptions,
                                                  background: effectiveBackground)
        case "eps", "ps":
            // EPS/PS have no alpha support: reject transparency and flatten.
            if exportOptions?.isTransparent == true {
                throw CLIError.invalid("transparent export is not supported for \(url.pathExtension.uppercased()); use PNG or PDF instead")
            }
            return try RasterExporter.export(scene: scene, camera: camera, to: url, size: size, options: effectiveOptions,
                                              background: effectiveBackground)
        case "png":
            return try PngExporter.export(scene: scene, camera: camera, to: url, size: size, options: effectiveOptions,
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
        case "pdf":
            // True vector: draw the graph view directly into a CGContext PDF page so
            // band/DOS/color-plane exports are real vector. Fall back to the raster
            // wrap on any failure so export never crashes.
            do {
                try writeGraphVectorPDF(view, to: url, size: size, background: background)
            } catch {
                try RasterExporter.write(cgImage: image, to: url, size: size)
            }
        case "svg", "eps", "ps":
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

    /// Draw a graph view directly into a CGContext PDF page for true vector output.
    /// The view is drawn through a flipped NSGraphicsContext with the same
    /// translate/scale convention as the bitmap branch in `exportGraph`.
    private static func writeGraphVectorPDF<View: NSView>(_ view: View, to url: URL,
                                                           size: CGSize,
                                                           background: (r: Double, g: Double, b: Double, a: Double)?) throws {
        let (width, height) = try validatedExportSize(size)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let data = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextCreator: "mcrysden"]
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw TrueVectorExportError.noContext
        }
        ctx.beginPDFPage(nil)
        if let bg = background, bg.a > 0 {
            ctx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            ctx.fill(mediaBox)
        }
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        nsCtx.cgContext.translateBy(x: 0, y: CGFloat(height))
        nsCtx.cgContext.scaleBy(x: 1, y: -1)
        // Only the flipped context assignment is needed: the labels/graph
        // expect a top-left-origin (isFlipped) coordinate system.
        let flipped = NSGraphicsContext(cgContext: nsCtx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        view.draw(view.bounds)
        nsCtx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// Edit > Copy Current View — render the live viewport scene/camera to a CGImage
    /// and place it on the general pasteboard. Momentary menu-title change is the
    /// lightweight success/failure feedback (no alert, no status bar).
    @MainActor
    @objc private func copyCurrentView(_ sender: Any?) {
        guard let wc = mainWC, let item = sender as? NSMenuItem else { return }
        let size = copyExportSize(for: wc)
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

    /// The image size used by Edit > Copy Current View.
    ///
    /// Normally the live viewport's logical size, matching File > Export. But a
    /// window that has not been laid out yet (copy invoked before the first
    /// layout pass, or from an off-screen/zero-sized window) reports zero -- or
    /// non-finite -- bounds, and `exportCurrentView` then throws with nothing but
    /// a one-second "Copy Failed" flash to show for it. Fall back to the export
    /// panel's configured dimensions so the copy still produces a usable image.
    @MainActor
    private func copyExportSize(for wc: MainWindowController) -> CGSize {
        let bounds = wc.viewport.bounds.size
        if bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 {
            return Self.exportSizeForViewport(bounds)
        }
        let fallback = CGSize(width: exportOptions.width, height: exportOptions.height)
        // exportOptions is user-editable; if it is itself degenerate, fall back
        // once more to the exporter's own default square.
        guard (try? Self.validatedExportSize(fallback)) != nil else {
            return CGSize(width: ExportOptions.defaultDimension,
                          height: ExportOptions.defaultDimension)
        }
        return fallback
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
    /// Clears all checkmarks when there is no active viewer.
    private func updateAnalysisCheckmarks() {
        // Read from `state` — the canonical source — so the checkmark reflects
        // the mode the menu just set, without depending on a pending sync.
        guard let analysis = analysisMenu else { return }
        guard let mode = mainWC?.state.measurementMode else {
            for item in analysis.items { item.state = .off }
            return
        }
        let activeTag: Int = { switch mode {
            case .none: return 1; case .distance: return 2; case .angle: return 3; case .dihedral: return 4
        } }()
        for item in analysis.items { item.state = (item.tag == activeTag) ? .on : .off }
    }

    /// Current app version, surfaced in --help output.
    static let appVersion = "1.2.7"

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
          mcrysden <file> --export out.pdf             # true vector export with a raster structure layer (pdf, svg); raster-backed container (eps, ps)
          mcrysden <file> --kpath route.kpf            # import a k-path (QE K_POINTS, VASP KPOINTS, Wannier90 kpoint_path, XCrySDen KPF)
          mcrysden <file> --convert out.xsf             # headless structure conversion (format by output extension)
          mcrysden <file> --convert-all dir --format xsf # headless batch conversion of a directory
          mcrysden <file> --pwi2xsf out.xsf             # convert a QE input to XSF
          mcrysden <file> --pwo2xsf out.xsf             # convert QE output to XSF
          mcrysden <file> --struct2xsf out.xsf          # convert WIEN2k .struct to XSF
          mcrysden <file> --export-anim out.gif         # headless animation export (.gif/.apng/.mp4)
          mcrysden <file> --script script.mvs           # run a headless script
          mcrysden --help
        Input formats are chosen by extension (\(exts)). Angstrom-based input
        (.cube/.bxsf/.struct) is kept in Angstrom; Bohr-based input is converted.
        Override the extension with a flag (any one):
          \(flags)
        For animated files (AXSF ANIMSTEPS, QE .pwo ionic steps, Orca opt cycles),
        open a specific frame with --frame N (0-based frame index).
        Export format is chosen by extension: .png (raster) or .pdf/.svg (true vector with raster structure layer) or .eps/.ps (raster-backed containers).
        Control multisampled antialiasing with --msaa 1|2|4|8 (1 = explicit Off override; omit to use scene default).
        Apply rendering-quality settings with --preset default|journal|presentation|print.
        Structure conversion formats are chosen by the --convert output extension:
          .xsf .cif .poscar/.contcar/.vasp .xyz .pwi/.in/.inp/.qe
        Batch --convert-all requires --format <xsf|cif|poscar|xyz|qe|struct|d12>; with a single-file
        --convert the output format comes from the output extension, so --format is
        accepted only when it names that same format.
        Animation --export-anim takes optional --fps N (default 10), --anim-size WxH
        (default 640x480), --frame N (0-based STARTING frame, default 0) and
        --frames K (export at most K frames from the start frame; default: all remaining).
        Only one of --export, --convert, --convert-all, --export-anim, --script may be used at once.
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
