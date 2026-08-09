import Foundation

struct ProjectBundle: Codable {
    var version: Int = 1
    var scene: Scene
}

enum ProjectStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported project version \(v) (expected 1)"
        case .malformed(let reason):
            return "Malformed project file: \(reason)"
        }
    }
}

/// Project/session files combining structures, bands, DOS, and volumetric data.
/// A project file is a JSON envelope (`ProjectBundle`) containing the scene.
enum ProjectStore {
    static func save(_ scene: Scene, to url: URL) throws {
        let bundle = ProjectBundle(version: 1, scene: scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        // Atomic write via rename(2): written to a temporary sibling then renamed
        // onto the target. No window where the file is missing (a crash between
        // the old remove+move would lose the previous project), and concurrent
        // CLI/GUI saves no longer race on a fixed `.tmp` name.
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> Scene {
        // Pre-check the on-disk size so a malicious/giant project file cannot
        // allocate unbounded memory. A 500k-atom project is ~30-60 MB of JSON;
        // 200 MB is a generous but bounded ceiling.
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int, fileSize > 200 * 1024 * 1024 {
                throw ProjectStoreError.malformed("project file too large (\(fileSize) bytes; limit 200 MB)")
            }
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            // File attribute errors fall through to Data(contentsOf:) below.
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectStoreError.malformed(error.localizedDescription)
        }
        let bundle: ProjectBundle
        do {
            bundle = try JSONDecoder().decode(ProjectBundle.self, from: data)
        } catch {
            throw ProjectStoreError.malformed(error.localizedDescription)
        }
        guard bundle.version == 1 else {
            throw ProjectStoreError.unsupportedVersion(bundle.version)
        }
        return bundle.scene
    }

    static func isValidProjectFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["scene"] != nil
    }
}
