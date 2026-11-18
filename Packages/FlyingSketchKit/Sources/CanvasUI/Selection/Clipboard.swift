import UIKit
import SketchCore

/// Object clipboard: JSON on `pasteboard` (general by default) under a private type id.
enum Clipboard {
    static let typeIdentifier = "com.flyingturtle.flyingsketch.objects"

    private struct Payload: Codable {
        var objects: [SceneObject]
        var assets: [String: Data]
    }

    /// The general pasteboard; tests substitute a private one.
    static var pasteboard = UIPasteboard.general

    static var hasContent: Bool { pasteboard.contains(pasteboardTypes: [typeIdentifier]) }

    static func write(_ objects: [SceneObject], assets: [String: Data]) {
        guard let data = try? JSONEncoder().encode(Payload(objects: objects, assets: assets)) else { return }
        pasteboard.setItems([[typeIdentifier: data]])
    }

    static func read() -> (objects: [SceneObject], assets: [String: Data])? {
        guard let data = pasteboard.data(forPasteboardType: typeIdentifier),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return (payload.objects, payload.assets)
    }

    /// Objects to insert into `document`: fresh ids, centred on `center`. Assets that would collide with a
    /// different asset of the same name are renamed (never overwritten); `assets` holds only the ones to add.
    static func prepare(_ objects: [SceneObject], assets: [String: Data], for document: SketchDocument,
                        centeredAt center: Vec2) -> (objects: [SceneObject], assets: [String: Data]) {
        guard let box = Rect.bounding(objects.flatMap { o -> [Vec2] in
            let b = bounds(of: o)
            return [Vec2(x: b.minX, y: b.minY), Vec2(x: b.maxX, y: b.maxY)]
        }) else { return ([], [:]) }
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

        let out = objects.map { o -> SceneObject in
            var moved = o.translated(by: delta).withID(.new())
            if case .image(var i) = moved {
                i.assetName = resolve(i.assetName)
                moved = .image(i)
            }
            return moved
        }
        return (out, toAdd)
    }
}
