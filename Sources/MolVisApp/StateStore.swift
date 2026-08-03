import Foundation
import CoreFoundation

// .mvis-state persistence. Matches the documented contract
// (docs/superpowers/specs/2026-07-06-mcrysden-design.md §8): a FLAT top-level
// object with the view-state fields the viewer needs to restore, plus the
// source file path (optional) and an optional camera. Atoms/bonds/cell are NOT
// saved — on load the app re-parses `source` for the structure and applies this
// view-state on top. This keeps state files tiny, diffable, and robust to Scene
// model changes.

enum StateStore {

    /// Persist the view-state. `sourceURL` is the loaded structure file (saved as
    /// `source`); pass nil only if the scene has no source (e.g. an empty
    /// viewer) — on reload the structure would need to be re-opened manually.
    static func save(_ scene: Scene, camera: Camera?, sourceURL: URL?, to url: URL,
                     kPathSampling: Int = 20,
                     cameraBookmarks: [CameraBookmark?] = []) throws {
        var payload: [String: Any] = ["version": 1]
        if let src = sourceURL { payload["source"] = src.path }
        payload["displayMode"] = scene.displayMode.rawValue
        payload["supercell"] = [scene.superCell.n1, scene.superCell.n2, scene.superCell.n3]
        if let slab = scene.slab {
            payload["slab"] = [
                "planeA": ["h": slab.planeA.h, "k": slab.planeA.k, "l": slab.planeA.l, "distance": slab.planeA.distance],
                "planeB": ["h": slab.planeB.h, "k": slab.planeB.k, "l": slab.planeB.l, "distance": slab.planeB.distance],
            ]
        }
        payload["background"] = scene.background
        payload["backgroundBottom"] = scene.backgroundBottom
        payload["backgroundType"] = scene.backgroundType.rawValue
        payload["showCellFrame"] = scene.showCellFrame
        payload["showAxes"] = scene.showAxes
        payload["showLabels"] = scene.showLabels
        payload["showBondDistances"] = scene.showBondDistances
        payload["showScaleIndicator"] = scene.showScaleIndicator
        payload["showBrillouinZone"] = scene.showBrillouinZone
        payload["showStructure"] = scene.showStructure
        payload["showIsoSurface"] = scene.showIsoSurface
        payload["isoLevel"] = scene.isoLevel
        payload["currentOrbital"] = scene.currentOrbital
        payload["showFermiSurface"] = scene.showFermiSurface
         payload["showForces"] = scene.showForces
        payload["showColorPlane"] = scene.showColorPlane
        payload["forceScale"] = scene.forceScale
        payload["msaaSampleCount"] = scene.msaaSampleCount
        payload["opacity"] = scene.opacity
        payload["lineWidth"] = scene.lineWidth
        payload["depthCueingStrength"] = scene.depthCueingStrength
        payload["aoStrength"] = scene.aoStrength
        payload["shadowStrength"] = scene.shadowStrength
        payload["aoQuality"] = scene.aoQuality
        payload["shadowQuality"] = scene.shadowQuality
        payload["atomScale"] = scene.atomScale
        payload["bondRadius"] = scene.bondRadius
        payload["lighting"] = [
            "ambient": scene.lighting.ambient, "diffuse": scene.lighting.diffuse,
            "specular": scene.lighting.specular, "shininess": scene.lighting.shininess,
            "azimuth": scene.lighting.azimuth, "elevation": scene.lighting.elevation,
        ]
        payload["currentFrame"] = scene.currentFrame
        // Per-segment k-path sampling density (UI-only preference). Persisted so a
        // saved session restores the user's export sampling choice; falls back to
        // 20 (the KPath default) for old state files that lack the key.
        payload["kPathSampling"] = kPathSampling
        // k-path: persist each point's fractional coords + label, the break set
        // (disconnected segment indices), and the provenance. Capped at load
        // time; here we just serialize what the scene holds (already bounded by
        // the editor, but keep the array compact for the flat format).
        payload["kPathPoints"] = scene.kPathPoints.map { kp in
            ["frac": [kp.frac.x, kp.frac.y, kp.frac.z], "label": kp.label]
        }
        // Persist breaks as a sorted array of indices. Empty array means fully
        // connected. Backward-compatible: old state files without this key
        // default to no breaks.
        payload["kPathBreaks"] = Array(scene.kPathBreaks).sorted()
        // Persist provenance so we know whether to regenerate on reload.
        payload["kPathProvenance"] = scene.kPathProvenance.rawValue
        // A generated route's signature is its identity with respect to the
        // source structure.  Do not serialize a stale signature onto a user
        // route: user coordinates are intentionally independent data.
        if scene.kPathProvenance == .generated, let signature = scene.kPathSignature {
            payload["kPathSignature"] = signature
        }
        // Fractional k-point coordinates are expressed in the *input*
        // reciprocal basis. Persist that direct-cell basis so an edited route
        // can be remapped safely if the source file is later replaced by an
        // equivalent-but-rotated/deformed input cell.
        if let cell = scene.cell {
            payload["kPathInputCell"] = [
                [cell.a.x, cell.a.y, cell.a.z],
                [cell.b.x, cell.b.y, cell.b.z],
                [cell.c.x, cell.c.y, cell.c.z],
            ]
        }
        if let camera {
            payload["camera"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera))
        }
        // New saves normalize even an empty input to the fixed three-slot
        // representation. The key remains optional when reading legacy files.
        payload["cameraBookmarks"] = try encodeCameraBookmarks(cameraBookmarks, url: url)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Apply a saved view-state onto an already-parsed `scene` (atoms/bonds/cell
    /// come from re-parsing `source`; this only restores the appearance/controls)
    /// and decode the optional `camera`. Malformed state throws a path-bearing
    /// ParseError and leaves both scene and camera unchanged.
    @discardableResult
    static func load(into scene: inout Scene, camera: inout Camera?, from url: URL) throws -> Int {
        var ignoredBookmarks: [CameraBookmark?] = []
        return try loadState(into: &scene, camera: &camera,
                             cameraBookmarks: &ignoredBookmarks, from: url)
    }

    /// Apply a saved view-state and restore the fixed camera-bookmark slots.
    /// The caller's scene, camera, and bookmarks are committed together only
    /// after the entire state file has been validated.
    @discardableResult
    static func load(into scene: inout Scene, camera: inout Camera?,
                     cameraBookmarks: inout [CameraBookmark?], from url: URL) throws -> Int {
        try loadState(into: &scene, camera: &camera,
                      cameraBookmarks: &cameraBookmarks, from: url)
    }

    private static func loadState(into scene: inout Scene, camera: inout Camera?,
                                  cameraBookmarks: inout [CameraBookmark?], from url: URL) throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.io(path: url.path, reason: error.localizedDescription)
        }
        let obj: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ParseError.io(path: url.path, reason: "bad state file")
            }
            obj = decoded
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.io(path: url.path, reason: "bad state file: \(error)")
        }
        if let value = obj["version"] {
            let v = try strictInteger(value, field: "version", url: url)
            if v > 1 {
                throw ParseError.parse(path: url.path, line: 0, reason: "state version \(v) too new")
            }
        }
        let dec = JSONDecoder()
        var candidate = scene
        var candidateCamera: Camera?
        func finiteFloat(_ value: Any?, field: String) throws -> Float? {
            guard let value = value as? Double else { return nil }
            let converted = Float(value)
            guard value.isFinite, converted.isFinite else {
                throw ParseError.parse(path: url.path, line: 0, reason: "non-finite state value: \(field)")
            }
            return converted
        }
        // displayMode (unknown -> .ballStick fallback, forward-compatible).
        if let mode = obj["displayMode"] as? String {
            candidate.displayMode = DisplayMode(rawValue: mode) ?? .ballStick
        }
        // supercell [n1,n2,n3]. Widen into atoms (not a bare field) so a saved
        // supercell is actually rendered — otherwise the restored view would show
        // only the base cell. baseAtoms is populated by Scene(loaded:) so the
        // expansion has source atoms to replicate. Validate first: negatives
        // would trap Swift's `0..<neg` range, and huge values could overflow the
        // atom-count multiplication, so clamp to [1, max] per the contract.
        if let sc = obj["supercell"] as? [Int], sc.count == 3 {
            // Clamp both bounds BEFORE multiplying so huge JSON ints can't overflow
            // the unchecked Int products (the old lower-only clamp still wrapped).
            // Validate per-axis limits separately (matching the sidebar steppers at
            // 1..6), THEN check total*atomCount against the atom cap. The old code
            // compared the raw product against 64, so a valid 6x6x6 (=216) supercell
            // was refused even though it's well under the cap.
            let perAxisMin = 1, perAxisMax = 6
            let dims = sc.map { min(perAxisMax, max(perAxisMin, $0)) }
            // Saturating multiply so malformed huge JSON ints can't trap Swift's
            // `Int` before the cap check runs.
            let d01 = dims[0].multipliedReportingOverflow(by: dims[1])
            let d012 = d01.partialValue.multipliedReportingOverflow(by: dims[2])
            guard !d01.overflow, !d012.overflow else {
                throw ParseError.parse(path: url.path, line: 0, reason: "saved supercell overflow")
            }
            let total = d012.partialValue
            let atomTotal = total.multipliedReportingOverflow(by: candidate.atoms.count)
            guard !atomTotal.overflow, atomTotal.partialValue <= Scene.superCellAtomCap else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "saved supercell would exceed atom cap")
            }
            candidate = candidate.widenSuperCell(SuperCell(n1: dims[0], n2: dims[1], n3: dims[2]))
        }
        // slab (optional). Assign the plane AND actually filter the atoms so a
        // saved slab is rendered — in headless export the scene is drawn
        // directly, so a bare field assignment would otherwise be ignored.
        // widenSuperCell (above) has already populated preslabAtoms with the
        // widened set that the slab should filter.
        if let slab = obj["slab"] as? [String: Any],
           let a = slab["planeA"] as? [String: Any], let b = slab["planeB"] as? [String: Any] {
            let distanceA = try finiteFloat(a["distance"], field: "slab.planeA.distance") ?? 0
            let distanceB = try finiteFloat(b["distance"], field: "slab.planeB.distance") ?? 0
            // Miller indices mirror the sidebar stepper contract exactly (-8...8),
            // so valid negatives (e.g. the default planeB k = -1) round-trip intact.
            func clampSlabIndex(_ v: Any?) -> Int { min(8, max(-8, v as? Int ?? 0)) }
            let sl = Slab(
                planeA: Plane(h: clampSlabIndex(a["h"]), k: clampSlabIndex(a["k"]), l: clampSlabIndex(a["l"]),
                              distance: distanceA),
                planeB: Plane(h: clampSlabIndex(b["h"]), k: clampSlabIndex(b["k"]), l: clampSlabIndex(b["l"]),
                              distance: distanceB))
            candidate = candidate.applySlab(sl)
        } else {
            candidate = candidate.applySlab(nil)
        }
        // appearance.
        if let bg = obj["background"] as? String { candidate.background = bg }
        if let bb = obj["backgroundBottom"] as? String { candidate.backgroundBottom = bb }
        if let bt = obj["backgroundType"] as? String { candidate.backgroundType = BackgroundType(rawValue: bt) ?? .solid }
        if let v = obj["showCellFrame"] as? Bool { candidate.showCellFrame = v }
        if let v = obj["showAxes"] as? Bool { candidate.showAxes = v }
        if let v = obj["showLabels"] as? Bool { candidate.showLabels = v }
        // Optional for backward compatibility; Scene defaults this to false when
        // an older state file does not contain the key.
        if let v = obj["showBondDistances"] as? Bool { candidate.showBondDistances = v }
        if let v = obj["showScaleIndicator"] as? Bool { candidate.showScaleIndicator = v }
        if let v = obj["showBrillouinZone"] as? Bool { candidate.showBrillouinZone = v }
        if let v = obj["showStructure"] as? Bool { candidate.showStructure = v }
        if let v = obj["showIsoSurface"] as? Bool { candidate.showIsoSurface = v }
        if !candidate.multiOrbitalFields.isEmpty {
            let requested = obj["currentOrbital"] as? Int ?? candidate.currentOrbital
            let index = min(max(0, requested), candidate.multiOrbitalFields.count - 1)
            candidate.currentOrbital = index
            candidate.scalarField = candidate.multiOrbitalFields[index]
        } else if let requested = obj["currentOrbital"] as? Int {
            candidate.currentOrbital = max(0, requested)
        }
        if let requested = try finiteFloat(obj["isoLevel"], field: "isoLevel") {
            if let field = candidate.scalarField {
                candidate.isoLevel = min(field.maxValue, max(field.minValue, requested))
            } else {
                candidate.isoLevel = requested
            }
        }
        if let v = obj["showFermiSurface"] as? Bool { candidate.showFermiSurface = v }
         if let v = obj["showForces"] as? Bool { candidate.showForces = v }
        // Color-plane toggle. Absent key (old state files) falls back to the
        // Scene default (true) — preserves the historical shown-when-present behavior.
        if let v = obj["showColorPlane"] as? Bool { candidate.showColorPlane = v }
        // Clamp to the sidebar's 5...200 range so a malformed state file can't feed
        // a negative/zero/giant scale into Metal (reversed or infinite arrow verts).
        if let v = try finiteFloat(obj["forceScale"], field: "forceScale") {
            candidate.forceScale = min(200, max(5, v))
        }
        // MSAA sample count. Backward-compatible: a missing key keeps the
        // Scene default (1 = off). A present value must be a mathematically
        // integral numeric token in {1,2,4,8}; strings, booleans, nonintegral
        // numerics (like 1.5), and unsupported integers all reject the whole
        // load transactionally (candidate is discarded, caller's
        // scene/camera/bookmarks preserved).
        if let raw = obj["msaaSampleCount"] {
            candidate.msaaSampleCount = try strictMSAASampleCount(raw, field: "msaaSampleCount", url: url)
        }
        // Rendering-quality fields. All optional for backward compatibility;
        // missing keys keep the Scene defaults (which preserve original output).
        if let v = try finiteFloat(obj["opacity"], field: "opacity") {
            candidate.opacity = min(1.0, max(0.0, v))
        }
        if let v = try finiteFloat(obj["lineWidth"], field: "lineWidth") {
            candidate.lineWidth = min(10.0, max(1.0, v))
        }
        if let v = try finiteFloat(obj["depthCueingStrength"], field: "depthCueingStrength") {
            candidate.depthCueingStrength = min(1.0, max(0.0, v))
        }
        if let v = try finiteFloat(obj["aoStrength"], field: "aoStrength") {
            candidate.aoStrength = min(1.0, max(0.0, v))
        }
        if let v = try finiteFloat(obj["shadowStrength"], field: "shadowStrength") {
            candidate.shadowStrength = min(1.0, max(0.0, v))
        }
        if let v = obj["aoQuality"] as? Int {
            candidate.aoQuality = min(3, max(0, v))
        }
        if let v = obj["shadowQuality"] as? Int {
            candidate.shadowQuality = min(3, max(0, v))
        }
        if let v = try finiteFloat(obj["atomScale"], field: "atomScale") { candidate.atomScale = min(1.0, max(0.05, v)) }
        if let v = try finiteFloat(obj["bondRadius"], field: "bondRadius") {
            candidate.bondRadius = min(1, max(0.001, v))
        }
        if let light = obj["lighting"] as? [String: Any] {
            var l = Lighting()
            l.ambient = try finiteFloat(light["ambient"], field: "lighting.ambient") ?? l.ambient
            l.diffuse = try finiteFloat(light["diffuse"], field: "lighting.diffuse") ?? l.diffuse
            l.specular = try finiteFloat(light["specular"], field: "lighting.specular") ?? l.specular
            l.shininess = try finiteFloat(light["shininess"], field: "lighting.shininess") ?? l.shininess
            l.azimuth = try finiteFloat(light["azimuth"], field: "lighting.azimuth") ?? l.azimuth
            l.elevation = try finiteFloat(light["elevation"], field: "lighting.elevation") ?? l.elevation
            candidate.lighting = l
        }
        if let v = obj["currentFrame"] as? Int { candidate.currentFrame = v }
        // k-path lifecycle. Keep the freshly parsed route as a snapshot before
        // applying persisted data: it is the authoritative canonical route for
        // the current source structure/input basis and lets old state files infer
        // whether their route was generated or user-edited.
        let freshPoints = candidate.kPathPoints
        let freshBreaks = candidate.kPathBreaks
        let freshProvenance = candidate.kPathProvenance
        let freshSignature = candidate.kPathSignature

        let hasPersistedPoints = obj["kPathPoints"] != nil
        let persistedPoints = try obj["kPathPoints"].map { try parseKPathPoints($0, url: url) }
        let routePoints = persistedPoints ?? freshPoints

        let persistedBreaks = try obj["kPathBreaks"].map {
            try parseKPathBreaks($0, pointCount: routePoints.count, url: url)
        }
        // For an old state with an explicit route but no break key, retain the
        // historical fully-connected interpretation. If the route key is absent,
        // preserve the freshly generated topology instead of clearing its breaks.
        let routeBreaks = persistedBreaks ?? (hasPersistedPoints ? [] : freshBreaks)

        let explicitProvenance: KPathProvenance?
        if let raw = obj["kPathProvenance"] {
            guard let string = raw as? String else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathProvenance must be a string")
            }
            guard let provenance = KPathProvenance(rawValue: string) else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "invalid kPathProvenance: \(string)")
            }
            explicitProvenance = provenance
        } else {
            explicitProvenance = nil
        }

        let persistedSignature: String?
        if let raw = obj["kPathSignature"] {
            guard let signature = raw as? String, !signature.isEmpty, signature.utf8.count <= 256 else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathSignature must be a non-empty string up to 256 bytes")
            }
            persistedSignature = signature
        } else {
            persistedSignature = nil
        }
        let persistedInputCell = try obj["kPathInputCell"].map { try parseKPathInputCell($0, url: url) }

        if hasPersistedPoints {
            // Pre-provenance state files cannot safely default to generated: a
            // custom route from an older app must not later be regenerated away.
            // It is generated only when it exactly matches the new scene's own
            // canonical route and topology.
            let provenance = explicitProvenance
                ?? ((routePoints == freshPoints && routeBreaks == freshBreaks) ? .generated : .userEdited)

            switch provenance {
            case .userEdited:
                if let savedCell = persistedInputCell, let currentCell = candidate.cell,
                   let remapped = Scene.remapKPathPoints(routePoints, from: savedCell, to: currentCell) {
                    candidate.kPathPoints = remapped
                } else {
                    // No saved/valid source basis means remapping is impossible;
                    // preserve the literal user coordinates non-destructively.
                    candidate.kPathPoints = routePoints
                }
                candidate.kPathBreaks = routeBreaks
                candidate.kPathProvenance = .userEdited
                candidate.kPathSignature = nil

            case .generated:
                // A generated route may be copied only when the state and freshly
                // parsed scene describe the same structure *and* input reciprocal
                // basis. Otherwise retain the new scene's canonical route.
                let signaturesAgree = persistedSignature == nil || freshSignature == nil
                    || persistedSignature == freshSignature
                let basesAgree: Bool
                if let savedCell = persistedInputCell, let currentCell = candidate.cell {
                    basesAgree = Scene.inputReciprocalBasesMatch(savedCell, currentCell) == true
                } else {
                    // Legacy state has no basis snapshot. It cannot establish a
                    // mismatch, so retain its historical behavior non-destructively.
                    basesAgree = true
                }
                if freshProvenance != .generated || (signaturesAgree && basesAgree) {
                    candidate.kPathPoints = routePoints
                    candidate.kPathBreaks = routeBreaks
                    candidate.kPathProvenance = .generated
                    candidate.kPathSignature = persistedSignature ?? freshSignature
                }
            }
        }
        // camera (optional). Wrap a malformed subtree as a path-bearing
        // ParseError (transactional rollback is preserved: scene/camera are only
        // committed at the end, so a throw here leaves the caller's state intact).
        if let c = obj["camera"] {
            do {
                let decoded = try dec.decode(Camera.self, from: try JSONSerialization.data(withJSONObject: c))
                candidateCamera = try Camera.validated(decoded)   // rejects non-finite / non-positive / invalid quaternion; normalizes
            } catch {
                throw ParseError.parse(path: url.path, line: 0, reason: "malformed camera: \(error)")
            }
        } else {
            candidateCamera = nil
        }
        // Camera bookmarks are optional for backward compatibility. A missing
        // key is the same as three empty slots; a present array is normalized
        // to the same fixed-size representation before the transaction commits.
        let candidateCameraBookmarks: [CameraBookmark?]
        if let rawBookmarks = obj["cameraBookmarks"] {
            candidateCameraBookmarks = try parseCameraBookmarks(rawBookmarks, url: url)
        } else {
            candidateCameraBookmarks = Array(repeating: nil, count: CameraBookmark.slotCount)
        }
        scene = candidate
        camera = candidateCamera
        cameraBookmarks = candidateCameraBookmarks
        // Per-segment k-path sampling density. Old state files lack the key and
        // fall back to the KPath default of 20. Clamp to UI bounds 2...200 so a
        // malformed or extreme saved value cannot steer the stepper or export.
        let raw = obj["kPathSampling"] as? Int
        return raw.map { min(200, max(2, $0)) } ?? 20
    }

    private static func encodeCameraBookmarks(_ bookmarks: [CameraBookmark?], url: URL) throws -> [Any] {
        guard bookmarks.count <= CameraBookmark.slotCount else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "cameraBookmarks has \(bookmarks.count) slots; maximum is \(CameraBookmark.slotCount)")
        }

        var encoded: [Any] = []
        encoded.reserveCapacity(CameraBookmark.slotCount)
        for index in 0..<CameraBookmark.slotCount {
            guard index < bookmarks.count, let bookmark = bookmarks[index] else {
                encoded.append(NSNull())
                continue
            }
            let name = try normalizedBookmarkName(bookmark.name, index: index, url: url)
            let camera: Camera
            do {
                camera = try Camera.validated(bookmark.camera)
            } catch {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "cameraBookmarks[\(index)].camera is invalid: \(error)")
            }
            let normalized = CameraBookmark(name: name, camera: camera)
            do {
                encoded.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalized)))
            } catch {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "cameraBookmarks[\(index)] could not be encoded: \(error)")
            }
        }
        return encoded
    }

    private static func parseCameraBookmarks(_ value: Any, url: URL) throws -> [CameraBookmark?] {
        guard let rawBookmarks = value as? [Any] else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "cameraBookmarks must be an array")
        }
        guard rawBookmarks.count <= CameraBookmark.slotCount else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "cameraBookmarks has \(rawBookmarks.count) slots; maximum is \(CameraBookmark.slotCount)")
        }

        let decoder = JSONDecoder()
        var parsed = Array<CameraBookmark?>(repeating: nil, count: CameraBookmark.slotCount)
        for index in rawBookmarks.indices {
            let rawBookmark = rawBookmarks[index]
            if rawBookmark is NSNull { continue }
            guard rawBookmark is [String: Any] else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "cameraBookmarks[\(index)] must be an object or null")
            }

            let bookmarkData: Data
            do {
                bookmarkData = try JSONSerialization.data(withJSONObject: rawBookmark, options: [])
            } catch {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "cameraBookmarks[\(index)] is not valid JSON: \(error)")
            }

            let decoded: CameraBookmark
            do {
                decoded = try decoder.decode(CameraBookmark.self, from: bookmarkData)
            } catch {
                throw ParseError.parse(path: url.path, line: 0, reason:
                                       "malformed cameraBookmarks[\(index)]: \(error)")
            }

            let name = try normalizedBookmarkName(decoded.name, index: index, url: url)
            let camera: Camera
            do {
                // Do not place the decoded camera into the result until this
                // validation has produced a finite camera with a normalized
                // quaternion.
                camera = try Camera.validated(decoded.camera)
            } catch {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "cameraBookmarks[\(index)].camera is invalid: \(error)")
            }
            parsed[index] = CameraBookmark(name: name, camera: camera)
        }
        return parsed
    }

    private static func normalizedBookmarkName(_ name: String, index: Int, url: URL) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "cameraBookmarks[\(index)].name must be non-empty after trimming")
        }
        guard trimmed.count <= 32 else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "cameraBookmarks[\(index)].name exceeds 32 characters")
        }
        return trimmed
    }

    private static func parseKPathPoints(_ value: Any, url: URL) throws -> [KPoint] {
        guard let arr = value as? [[String: Any]] else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "kPathPoints must be an array of {frac, label} dictionaries")
        }
        let cap = 1024
        guard arr.count <= cap else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "kPathPoints count \(arr.count) exceeds cap \(cap)")
        }
        var points: [KPoint] = []
        points.reserveCapacity(arr.count)
        for (index, item) in arr.enumerated() {
            guard let rawFraction = item["frac"] as? [Any], rawFraction.count == 3,
                  let label = item["label"] as? String else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "malformed kPathPoints[\(index)]")
            }
            guard label.count <= 64 else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathPoints[\(index)] label too long (\(label.count) > 64)")
            }
            let x = try finiteJSONFloat(rawFraction[0], field: "kPathPoints[\(index)].frac[0]", url: url)
            let y = try finiteJSONFloat(rawFraction[1], field: "kPathPoints[\(index)].frac[1]", url: url)
            let z = try finiteJSONFloat(rawFraction[2], field: "kPathPoints[\(index)].frac[2]", url: url)
            points.append(KPoint(SIMD3<Float>(x, y, z), label))
        }
        return points
    }

    private static func parseKPathBreaks(_ value: Any, pointCount: Int, url: URL) throws -> Set<Int> {
        guard let rawBreaks = value as? [Any] else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "kPathBreaks must be an array of integers")
        }
        if pointCount > 0 {
            guard rawBreaks.count < pointCount else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathBreaks count \(rawBreaks.count) >= point count \(pointCount)")
            }
        } else {
            guard rawBreaks.isEmpty else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathBreaks non-empty with zero points")
            }
        }

        var breaks = Set<Int>()
        for (index, rawBreak) in rawBreaks.enumerated() {
            let breakIndex = try strictInteger(rawBreak, field: "kPathBreaks[\(index)]", url: url)
            guard breakIndex >= 0, breakIndex < pointCount - 1 else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathBreaks[\(index)] = \(breakIndex) out of range for \(pointCount) points")
            }
            guard breaks.insert(breakIndex).inserted else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "duplicate kPathBreaks entry: \(breakIndex)")
            }
        }
        return breaks
    }

    private static func parseKPathInputCell(_ value: Any, url: URL) throws -> Cell {
        guard let rows = value as? [Any], rows.count == 3 else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "kPathInputCell must be a 3x3 numeric array")
        }
        var vectors: [SIMD3<Float>] = []
        vectors.reserveCapacity(3)
        for (rowIndex, rowValue) in rows.enumerated() {
            guard let components = rowValue as? [Any], components.count == 3 else {
                throw ParseError.parse(path: url.path, line: 0,
                                       reason: "kPathInputCell[\(rowIndex)] must have three numeric components")
            }
            vectors.append(SIMD3<Float>(
                try finiteJSONFloat(components[0], field: "kPathInputCell[\(rowIndex)][0]", url: url),
                try finiteJSONFloat(components[1], field: "kPathInputCell[\(rowIndex)][1]", url: url),
                try finiteJSONFloat(components[2], field: "kPathInputCell[\(rowIndex)][2]", url: url)
            ))
        }
        return Cell(a: vectors[0], b: vectors[1], c: vectors[2])
    }

    /// JSON has a single generic number type. Accept integral numeric tokens
    /// (including `1.0`) but reject booleans, fractions, non-finite values, and
    /// values outside the safe `Int` conversion range.
    private static func strictInteger(_ value: Any, field: String, url: URL) throws -> Int {
        guard let number = value as? NSNumber, !isJSONBoolean(number) else {
            throw ParseError.parse(path: url.path, line: 0, reason: "\(field) must be an integer")
        }
        let decimal = number.doubleValue
        guard decimal.isFinite, decimal.rounded(.towardZero) == decimal,
              decimal > Double(Int.min), decimal < Double(Int.max) else {
            throw ParseError.parse(path: url.path, line: 0, reason: "\(field) must be an integer")
        }
        return Int(decimal)
    }

    /// MSAA sample count: accept any mathematically integral numeric token
    /// in {1,2,4,8}. Reject strings, booleans, nonintegral numerics (like
    /// 1.5), and any integer outside the set — all transactionally via
    /// ParseError (candidate is discarded, caller state preserved).
    private static func strictMSAASampleCount(_ value: Any, field: String, url: URL) throws -> Int {
        let intVal = try strictInteger(value, field: field, url: url)
        guard [1, 2, 4, 8].contains(intVal) else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "\(field) must be 1, 2, 4, or 8; got \(intVal)")
        }
        return intVal
    }

    private static func finiteJSONFloat(_ value: Any, field: String, url: URL) throws -> Float {
        guard let number = value as? NSNumber, !isJSONBoolean(number) else {
            throw ParseError.parse(path: url.path, line: 0, reason: "\(field) must be a finite number")
        }
        let decimal = number.doubleValue
        let converted = Float(decimal)
        guard decimal.isFinite, converted.isFinite else {
            throw ParseError.parse(path: url.path, line: 0, reason: "non-finite state value: \(field)")
        }
        return converted
    }

    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
