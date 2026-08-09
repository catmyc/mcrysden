import Foundation

/// Errors from headless batch conversion. `errorDescription` is user-facing
/// (CLI), so it names the offending path/format rather than exposing internals.
enum ConverterError: Error, LocalizedError {
    case unsupportedOutputExtension(String)
    case outputAliasesInput
    case noAtoms
    case loadFailed(String)
    case writeFailed(String)
    case tooManyFiles(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedOutputExtension(let ext): return "unsupported output extension: \(ext)"
        case .outputAliasesInput: return "output path aliases the input file"
        case .noAtoms: return "input file contains no atoms"
        case .loadFailed(let path): return "failed to load \(path)"
        case .writeFailed(let path): return "failed to write \(path)"
        case .tooManyFiles(let n): return "too many input files (\(n)); increase maxFiles"
        }
    }
}

/// Pure, testable headless structure conversion: load → serialize → atomic write.
enum Converter {
    /// Map a lowercased output path extension to a structure format.
    static func outputFormat(forExtension ext: String) -> StructureExportFormat? {
        switch ext.lowercased() {
        case "xsf": return .xsf
        case "cif": return .cif
        case "poscar", "contcar", "vasp": return .poscar
        case "xyz": return .xyz
        case "pwi", "in", "inp", "qe": return .qeInput
        case "struct": return .wienStruct
        case "d12", "crystal": return .crystal03
        default: return nil
        }
    }

    /// The on-disk extension used when writing `targetFormat` in batch mode.
    static func outputNameExtension(for targetFormat: StructureExportFormat) -> String {
        switch targetFormat {
        case .xsf: return "xsf"
        case .cif: return "cif"
        case .poscar: return "poscar"
        case .xyz: return "xyz"
        case .qeInput: return "pwi"
        case .wienStruct: return "struct"
        case .crystal95, .crystal98, .crystal03, .crystalNew: return "d12"
        }
    }

    /// Convert a single structure file to `outputURL`. The output format is
    /// inferred from `outputURL`'s extension; `forcedFormat` overrides the
    /// input parser. Writes through a temp file then atomically replaces the
    /// destination so an interrupted conversion can never leave a truncated file.
    static func convert(url: URL, to outputURL: URL, forcedFormat: ParseFormat?, frameIndex: Int = 0) throws {
        let inputPath = url.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        guard inputPath != outputPath else { throw ConverterError.outputAliasesInput }

        let loaded = try Parser.load(url, as: forcedFormat, frameIndex: frameIndex)
        let scene = Scene(loaded: loaded)
        guard !scene.atoms.isEmpty else { throw ConverterError.noAtoms }

        guard let format = outputFormat(forExtension: outputURL.pathExtension) else {
            throw ConverterError.unsupportedOutputExtension(outputURL.pathExtension)
        }
        let text = try StructureWriter.write(scene, as: format)

        let parent = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw ConverterError.writeFailed(outputURL.path)
            }
        }
        let tmp = parent.appendingPathComponent(".mcrysden-conv-\(UUID().uuidString).tmp")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            let fm = FileManager.default
            if fm.fileExists(atPath: outputPath) {
                try fm.replaceItemAt(outputURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ConverterError.writeFailed(outputURL.path)
        }
    }

    /// Convert every loadable regular file in `inputDirectory` to `targetFormat`
    /// under `outputDirectory`. Unparseable files AND files that cannot be
    /// expressed in the target format (e.g. a molecule written to CIF) are skipped;
    /// only genuine write failures and the maxFiles cap throw. Returns the success
    /// count. Bounded at `maxFiles` and deterministic (sorted by name).
    static func convertAll(inputDirectory: URL, outputDirectory: URL, targetFormat: StructureExportFormat,
                           forcedFormat: ParseFormat?, maxFiles: Int = 200) throws -> Int {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil)
        let files = entries.filter { url in
            guard !url.hasDirectoryPath else { return false }
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard files.count <= maxFiles else { throw ConverterError.tooManyFiles(files.count) }

        if !fm.fileExists(atPath: outputDirectory.path) {
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let ext = outputNameExtension(for: targetFormat)
        var count = 0
        var seenOutputs: [URL: String] = [:]   // output URL -> input name (for diagnostics)
        for file in files {
            let outURL = outputDirectory
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(ext)
            // Two inputs with the same stem ("a.xyz", "a.pdb") map to the same
            // output ("a.xsf"). The later conversion would silently overwrite
            // the earlier while the success count still reports both. Skip the
            // duplicate deterministically (the list is sorted) and warn.
            if let existingName = seenOutputs[outURL] {
                print("[mcrysden] convert-all: skipping \(file.lastPathComponent): output collides with \(existingName)")
                continue
            }
            seenOutputs[outURL] = file.lastPathComponent
            do {
                try convert(url: file, to: outURL, forcedFormat: forcedFormat)
                count += 1
            } catch is ParseError {
                continue   // skip unparseable files (e.g. garbage input)
            } catch let e as StructureWriteError {
                continue   // skip files inexpressible in the target format (e.g. molecule -> CIF)
            } catch let e as ConverterError {
                switch e {
                case .loadFailed, .noAtoms, .outputAliasesInput, .unsupportedOutputExtension:
                    continue   // skip unparseable / unsupported inputs
                case .writeFailed, .tooManyFiles:
                    throw e
                }
            }
        }
        return count
    }
}
