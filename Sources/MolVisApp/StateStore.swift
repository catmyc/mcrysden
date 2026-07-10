import Foundation

// .molvis-state persistence. Matches the documented contract
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
    static func save(_ scene: Scene, camera: Camera?, sourceURL: URL?, to url: URL) throws {
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
        payload["showBrillouinZone"] = scene.showBrillouinZone
        payload["showStructure"] = scene.showStructure
        payload["atomScale"] = scene.atomScale
        payload["bondRadius"] = scene.bondRadius
        payload["lighting"] = [
            "ambient": scene.lighting.ambient, "diffuse": scene.lighting.diffuse,
            "specular": scene.lighting.specular, "shininess": scene.lighting.shininess,
            "azimuth": scene.lighting.azimuth, "elevation": scene.lighting.elevation,
        ]
        payload["currentFrame"] = scene.currentFrame
        if let camera {
            payload["camera"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera))
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Apply a saved view-state onto an already-parsed `scene` (atoms/bonds/cell
    /// come from re-parsing `source`; this only restores the appearance/controls)
    /// and decode the optional `camera`. Never throws on a malformed file — it
    /// warns and either falls back to defaults or aborts the load, leaving the
    /// current scene intact (spec §9).
    static func load(into scene: inout Scene, camera: inout Camera?, from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.io(path: url.path, reason: "bad state file")
        }
        if let v = obj["version"] as? Int, v > 1 {
            throw ParseError.parse(path: url.path, line: 0, reason: "state version \(v) too new")
        }
        let dec = JSONDecoder()

        // displayMode (unknown -> .ballStick fallback, forward-compatible).
        if let mode = obj["displayMode"] as? String {
            scene.displayMode = DisplayMode(rawValue: mode) ?? .ballStick
        }
        // supercell [n1,n2,n3]. Widen into atoms (not a bare field) so a saved
        // supercell is actually rendered — otherwise the restored view would show
        // only the base cell. baseAtoms is populated by Scene(loaded:) so the
        // expansion has source atoms to replicate.
        if let sc = obj["supercell"] as? [Int], sc.count == 3 {
            scene = scene.widenSuperCell(SuperCell(n1: sc[0], n2: sc[1], n3: sc[2]))
        }
        // slab (optional).
        if let slab = obj["slab"] as? [String: Any],
           let a = slab["planeA"] as? [String: Any], let b = slab["planeB"] as? [String: Any] {
            scene.slab = Slab(
                planeA: Plane(h: a["h"] as? Int ?? 0, k: a["k"] as? Int ?? 1, l: a["l"] as? Int ?? 0,
                              distance: (a["distance"] as? Double).map(Float.init) ?? 0),
                planeB: Plane(h: b["h"] as? Int ?? 0, k: b["k"] as? Int ?? -1, l: b["l"] as? Int ?? 0,
                              distance: (b["distance"] as? Double).map(Float.init) ?? 0))
        } else {
            scene.slab = nil
        }
        // appearance.
        if let bg = obj["background"] as? String { scene.background = bg }
        if let bb = obj["backgroundBottom"] as? String { scene.backgroundBottom = bb }
        if let bt = obj["backgroundType"] as? String { scene.backgroundType = BackgroundType(rawValue: bt) ?? .solid }
        if let v = obj["showCellFrame"] as? Bool { scene.showCellFrame = v }
        if let v = obj["showAxes"] as? Bool { scene.showAxes = v }
        if let v = obj["showLabels"] as? Bool { scene.showLabels = v }
        if let v = obj["showBrillouinZone"] as? Bool { scene.showBrillouinZone = v }
        if let v = obj["showStructure"] as? Bool { scene.showStructure = v }
        if let v = obj["atomScale"] as? Double { scene.atomScale = Float(v) }
        if let v = obj["bondRadius"] as? Double { scene.bondRadius = Float(v) }
        if let light = obj["lighting"] as? [String: Any] {
            var l = Lighting()
            l.ambient = (light["ambient"] as? Double).map(Float.init) ?? l.ambient
            l.diffuse = (light["diffuse"] as? Double).map(Float.init) ?? l.diffuse
            l.specular = (light["specular"] as? Double).map(Float.init) ?? l.specular
            l.shininess = (light["shininess"] as? Double).map(Float.init) ?? l.shininess
            l.azimuth = (light["azimuth"] as? Double).map(Float.init) ?? l.azimuth
            l.elevation = (light["elevation"] as? Double).map(Float.init) ?? l.elevation
            scene.lighting = l
        }
        if let v = obj["currentFrame"] as? Int { scene.currentFrame = v }
        // camera (optional).
        if let c = obj["camera"] {
            camera = try dec.decode(Camera.self, from: try JSONSerialization.data(withJSONObject: c))
        } else {
            camera = nil
        }
    }
}
