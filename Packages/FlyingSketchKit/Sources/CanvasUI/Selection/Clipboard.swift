import UIKit
import SketchCore

/// Object clipboard: JSON on `pasteboard` (general by default) under a private type id.
enum Clipboard {
    static let typeIdentifier = "com.flyingturtle.flyingsketch.objects"

    struct Contents {
        var objects: [SceneObject]
        /// Image assets and the graphic assets of `definitions`.
        var assets: [String: Data]
        /// Definitions of the copied parts, by key.
        var definitions: [String: PartDefinition]
    }

    private struct Payload: Codable {
        var objects: [SceneObject]
        var assets: [String: Data]
        var definitions: [String: PartDefinition]

        init(objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition]) {
            self.objects = objects
            self.assets = assets
            self.definitions = definitions
        }

        // Payloads written before parts existed have no `definitions`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            objects = try c.decode([SceneObject].self, forKey: .objects)
            assets = try c.decode([String: Data].self, forKey: .assets)
            definitions = try c.decodeIfPresent([String: PartDefinition].self, forKey: .definitions) ?? [:]
        }
    }

    /// The general pasteboard; tests substitute a private one.
    static var pasteboard = UIPasteboard.general

    static var hasContent: Bool { pasteboard.contains(pasteboardTypes: [typeIdentifier]) }

    static func write(_ objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition] = [:]) {
        let payload = Payload(objects: objects, assets: assets, definitions: definitions)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        pasteboard.setItems([[typeIdentifier: data]])
    }

    static func read() -> Contents? {
        guard let data = pasteboard.data(forPasteboardType: typeIdentifier),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return Contents(objects: payload.objects, assets: payload.assets, definitions: payload.definitions)
    }

    /// Objects to insert into `document`: fresh ids, centred on `center`, labels renumbered, wire attachments kept
    /// only between pasted objects (see `cloned`). Assets that would collide with a different asset of the same name
    /// are renamed (never overwritten); `assets` holds only the ones to add. `definitions` holds only definitions
    /// missing from `document` (an existing key keeps the document's definition).
    static func prepare(_ objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition] = [:],
                        for document: SketchDocument, centeredAt center: Vec2)
        -> (objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition]) {
        var withDefinitions = document
        withDefinitions.parts.merge(definitions) { existing, _ in existing }
        guard let box = Rect.bounding(objects.flatMap { o -> [Vec2] in
            let b = bounds(of: o, in: withDefinitions)
            return [Vec2(x: b.minX, y: b.minY), Vec2(x: b.maxX, y: b.maxY)]
        }) else { return ([], [:], [:]) }
        let delta = center - Vec2(x: box.minX + box.size.x / 2, y: box.minY + box.size.y / 2)

        var renamed: [String: String] = [:]
        var toAdd: [String: Data] = [:]
        func resolve(_ name: String) -> String {
            if let r = renamed[name] { return r }
            var result = name
            if let data = assets[name] {
                if let existing = document.assets[name], existing != data {
                    let ns = name as NSString
                    let ext = ns.pathExtension
                    let suffix = String(UUID().uuidString.prefix(8))
                    result = ext.isEmpty ? "\(name)-\(suffix)" : "\(ns.deletingPathExtension)-\(suffix).\(ext)"
                }
                if document.assets[result] == nil { toAdd[result] = data }
            }
            renamed[name] = result
            return result
        }

        var newDefinitions: [String: PartDefinition] = [:]
        for case .part(let p) in objects where document.parts[p.definitionKey] == nil {
            guard newDefinitions[p.definitionKey] == nil, var def = definitions[p.definitionKey] else { continue }
            def.graphicAsset = resolve(def.graphicAsset)
            newDefinitions[def.key] = def
        }
        let out = cloned(objects, by: delta, into: document, definitions: definitions).map { o -> SceneObject in
            guard case .image(var i) = o else { return o }
            i.assetName = resolve(i.assetName)
            return .image(i)
        }
        return (out, toAdd, newDefinitions)
    }
}
