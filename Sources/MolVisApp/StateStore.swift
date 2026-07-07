import Foundation

enum StateStore {
    static func save(_ scene: Scene, camera: Camera?, to url: URL) throws {
        var payload: [String: Any] = ["version": 1]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        payload["scene"] = try JSONSerialization.jsonObject(with: try enc.encode(scene))
        if let camera {
            payload["camera"] = try JSONSerialization.jsonObject(with: try enc.encode(camera))
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: url)
    }

    static func load(_ scene: inout Scene, camera: inout Camera?, from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.io(path: url.path, reason: "bad state file")
        }
        if let v = obj["version"] as? Int, v > 1 {
            throw ParseError.parse(path: url.path, line: 0, reason: "state version \(v) too new")
        }
        let dec = JSONDecoder()
        if let s = obj["scene"] {
            scene = try dec.decode(Scene.self, from: try JSONSerialization.data(withJSONObject: s))
        }
        if let c = obj["camera"] {
            camera = try dec.decode(Camera.self, from: try JSONSerialization.data(withJSONObject: c))
        } else {
            camera = nil
        }
    }
}
