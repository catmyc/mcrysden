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
        payload["showIsoSurface"] = scene.showIsoSurface
        payload["isoLevel"] = scene.isoLevel
        payload["currentOrbital"] = scene.currentOrbital
        payload["showFermiSurface"] = scene.showFermiSurface
        payload["showForces"] = scene.showForces
        payload["forceScale"] = scene.forceScale
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
                print("[mcrysden] warning: saved supercell (\(dims)) refused (overflow)")
                return
            }
            let total = d012.partialValue
            guard !total.multipliedReportingOverflow(by: scene.atoms.count).overflow,
                  total * scene.atoms.count <= Scene.superCellAtomCap else {
                print("[mcrysden] warning: saved supercell (\(dims)) refused (would exceed atom cap)")
                return
            }
            scene = scene.widenSuperCell(SuperCell(n1: dims[0], n2: dims[1], n3: dims[2]))
        }
        // slab (optional). Assign the plane AND actually filter the atoms so a
        // saved slab is rendered — in headless export the scene is drawn
        // directly, so a bare field assignment would otherwise be ignored.
        // widenSuperCell (above) has already populated preslabAtoms with the
        // widened set that the slab should filter.
        if let slab = obj["slab"] as? [String: Any],
           let a = slab["planeA"] as? [String: Any], let b = slab["planeB"] as? [String: Any] {
            let sl = Slab(
                planeA: Plane(h: a["h"] as? Int ?? 0, k: a["k"] as? Int ?? 1, l: a["l"] as? Int ?? 0,
                              distance: (a["distance"] as? Double).map(Float.init) ?? 0),
                planeB: Plane(h: b["h"] as? Int ?? 0, k: b["k"] as? Int ?? -1, l: b["l"] as? Int ?? 0,
                              distance: (b["distance"] as? Double).map(Float.init) ?? 0))
            scene = scene.applySlab(sl)
        } else {
            scene = scene.applySlab(nil)
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
        if let v = obj["showIsoSurface"] as? Bool { scene.showIsoSurface = v }
        if !scene.multiOrbitalFields.isEmpty {
            let requested = obj["currentOrbital"] as? Int ?? scene.currentOrbital
            let index = min(max(0, requested), scene.multiOrbitalFields.count - 1)
            scene.currentOrbital = index
            scene.scalarField = scene.multiOrbitalFields[index]
        } else if let requested = obj["currentOrbital"] as? Int {
            scene.currentOrbital = max(0, requested)
        }
        if let v = obj["isoLevel"] as? Double {
            let requested = Float(v)
            if let field = scene.scalarField {
                scene.isoLevel = min(field.maxValue, max(field.minValue, requested))
            } else {
                scene.isoLevel = requested
            }
        }
        if let v = obj["showFermiSurface"] as? Bool { scene.showFermiSurface = v }
        if let v = obj["showForces"] as? Bool { scene.showForces = v }
        // Clamp to the sidebar's 5...200 range so a malformed state file can't feed
        // a negative/zero/giant scale into Metal (reversed or infinite arrow verts).
        if let v = obj["forceScale"] as? Double {
            scene.forceScale = min(200, max(5, Float(v)))
        }
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
