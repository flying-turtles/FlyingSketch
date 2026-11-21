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
        /// Groups whose members are all in `objects`.
        var groups: [ObjectGroup]
    }

    private struct Payload: Codable {
        var objects: [SceneObject]
        var assets: [String: Data]
        var definitions: [String: PartDefinition]
        var groups: [ObjectGroup]

        init(objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition],
             groups: [ObjectGroup]) {
            self.objects = objects
            self.assets = assets
            self.definitions = definitions
            self.groups = groups
        }

        // Payloads written before parts existed have no `definitions`, before joints no `groups`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            objects = try c.decode([SceneObject].self, forKey: .objects)
            assets = try c.decode([String: Data].self, forKey: .assets)
            definitions = try c.decodeIfPresent([String: PartDefinition].self, forKey: .definitions) ?? [:]
            groups = try c.decodeIfPresent([ObjectGroup].self, forKey: .groups) ?? []
        }
    }

    /// The general pasteboard; tests substitute a private one.
    static var pasteboard = UIPasteboard.general

    static var hasContent: Bool { pasteboard.contains(pasteboardTypes: [typeIdentifier]) }

    static func write(_ objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition] = [:],
                      groups: [ObjectGroup] = []) {
        let payload = Payload(objects: objects, assets: assets, definitions: definitions, groups: groups)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        pasteboard.setItems([[typeIdentifier: data]])
    }

    static func read() -> Contents? {
        guard let data = pasteboard.data(forPasteboardType: typeIdentifier),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let safe = sanitized(payload.objects, assets: payload.assets, definitions: payload.definitions,
                             groups: payload.groups)
        return Contents(objects: safe.objects, assets: safe.assets, definitions: safe.definitions, groups: safe.groups)
    }

    /// Pasteboard data is untrusted: drops assets with unsafe names, images referencing one, definitions that are
    /// mis-keyed or fail `PartDefinition.validate()` (geometry, graphic asset name), and the parts that would use
    /// such a dropped definition. Joints with an anchor outside the (surviving) objects and groups with a member
    /// outside them are dropped too: no dangling references.
    static func sanitized(_ objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition],
                          groups: [ObjectGroup] = [])
        -> (objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition],
            groups: [ObjectGroup]) {
        let safeAssets = assets.filter { isSafeAssetName($0.key) }
        var safeDefinitions: [String: PartDefinition] = [:]
        var rejected: Set<String> = []
        for (key, def) in definitions {
            if key == def.key, (try? def.validate()) != nil { safeDefinitions[key] = def } else { rejected.insert(key) }
        }
        let safeObjects = objects.filter { o in
            switch o {
            case .image(let i): isSafeAssetName(i.assetName)
            case .part(let p): !rejected.contains(p.definitionKey)
            default: true
            }
        }
        var seenIDs = Set<ObjectID>()
        let unique = safeObjects.filter { seenIDs.insert($0.id).inserted } // clones are keyed by id
        let bodies = Set(unique.compactMap { o -> ObjectID? in
            switch o {
            case .wire, .joint: nil
            default: o.id
            }
        })
        let consistent = unique.filter { o in
            guard case .joint(let j) = o else { return true }
            return j.anchors.allSatisfy { bodies.contains($0.object) }
        }
        let safeGroups = groups.filter { $0.members.allSatisfy { bodies.contains($0) } }
        // The document's own repair rules (empty / single / overlapping / colliding groups, invalid joints).
        var checked = SketchDocument(objects: consistent, groups: safeGroups)
        for edit in jointIntegrityEdits(in: checked) { _ = edit.apply(to: &checked) }
        return (checked.objects, safeAssets, safeDefinitions, checked.groups)
    }

    /// `selected` plus the joints of `doc` that the selection implies: every joint not selected whose anchor bodies
    /// are all fully selected (a body is its whole group) rides along, so copied bars keep their pins and locks.
    /// A joint with any anchor body outside the selection stays out. Result is in document z-order.
    static func withBodyJoints(_ selected: [SceneObject], in doc: SketchDocument) -> [SceneObject] {
        let ids = Set(selected.map(\.id))
        func copied(_ object: ObjectID) -> Bool {
            bodyMembers(bodyID(of: object, in: doc), in: doc).allSatisfy(ids.contains)
        }
        let extra = Set(doc.objects.compactMap { o -> ObjectID? in
            guard case .joint(let j) = o, !ids.contains(j.id), !j.anchors.isEmpty,
                  j.anchors.allSatisfy({ copied($0.object) }) else { return nil }
            return j.id
        })
        guard !extra.isEmpty else { return selected }
        return doc.objects.filter { ids.contains($0.id) || extra.contains($0.id) }
    }

    /// Objects to insert into `document`: fresh ids, centred on `center`, labels renumbered, wire attachments kept
    /// only between pasted objects, joints and groups only when complete (see `cloned`). Assets that would collide with a different asset of the same name
    /// are renamed (never overwritten); `assets` holds only the ones to add. `definitions` holds only definitions
    /// missing from `document` (an existing key keeps the document's definition).
    static func prepare(_ objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition] = [:],
                        groups: [ObjectGroup] = [], for document: SketchDocument, centeredAt center: Vec2)
        -> (objects: [SceneObject], assets: [String: Data], definitions: [String: PartDefinition],
            groups: [ObjectGroup]) {
        let (objects, assets, definitions, groups) = sanitized(objects, assets: assets, definitions: definitions,
                                                               groups: groups)
        var withDefinitions = document
        withDefinitions.parts.merge(definitions) { existing, _ in existing }
        guard let box = Rect.bounding(objects.flatMap { o -> [Vec2] in
            let b = bounds(of: o, in: withDefinitions)
            return [Vec2(x: b.minX, y: b.minY), Vec2(x: b.maxX, y: b.maxY)]
        }) else { return ([], [:], [:], []) }
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
        let copies = cloned(objects, groups: groups, by: delta, into: document, definitions: definitions)
        let out = copies.objects.map { o -> SceneObject in
            guard case .image(var i) = o else { return o }
            i.assetName = resolve(i.assetName)
            return .image(i)
        }
        return (out, toAdd, newDefinitions, copies.groups)
    }
}
