import Foundation

/// `.flysketch` package: `document.json` + `assets/<name>`.
public enum DocumentPackage {
    private static let jsonName = "document.json"
    private static let assetsName = "assets"

    private struct VersionProbe: Decodable { var formatVersion: Int }

    private struct Body: Codable {
        var formatVersion: Int
        var objects: [SceneObject]
        var viewport: Viewport
        /// Absent in v1 documents.
        var parts: [String: PartDefinition]?
        /// Absent before v4.
        var groups: [ObjectGroup]?
    }

    /// Throws `corrupt("unsafe asset name")` for any asset name that is not `isSafeAssetName` (a FileWrapper key
    /// like `../x` would be written outside the package).
    public static func fileWrapper(for doc: SketchDocument) throws -> FileWrapper {
        if doc.assets.keys.contains(where: { !isSafeAssetName($0) }) { throw DocumentError.corrupt("unsafe asset name") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = Body(formatVersion: 4, objects: doc.objects, viewport: doc.viewport, parts: doc.parts,
                    groups: doc.groups)
        let json = try encoder.encode(body)

        var assets: [String: FileWrapper] = [:]
        for (name, data) in doc.assets {
            let w = FileWrapper(regularFileWithContents: data)
            w.preferredFilename = name
            assets[name] = w
        }
        let root = FileWrapper(directoryWithFileWrappers: [
            jsonName: FileWrapper(regularFileWithContents: json),
            assetsName: FileWrapper(directoryWithFileWrappers: assets),
        ])
        return root
    }

    public static func read(_ wrapper: FileWrapper) throws -> SketchDocument {
        guard let json = wrapper.fileWrappers?[jsonName]?.regularFileContents else {
            throw DocumentError.missingDocumentJSON
        }
        let decoder = JSONDecoder()
        let body: Body
        do {
            // Version first: newer documents may have a different object schema.
            let version = try decoder.decode(VersionProbe.self, from: json).formatVersion
            if version > 4 { throw DocumentError.unsupportedVersion(version) }
            if version < 1 { throw DocumentError.corrupt("invalid formatVersion \(version)") }
            body = try decoder.decode(Body.self, from: json)
        } catch let e as DocumentError {
            throw e
        } catch {
            throw DocumentError.corrupt(String(describing: error))
        }

        let parts = body.parts ?? [:]
        try validate(body.objects, body.viewport, parts)
        if let (key, _) = parts.first(where: { $0.key != $0.value.key }) {
            throw DocumentError.corrupt("part definition stored under mismatched key \(key)")
        }

        var assets: [String: Data] = [:]
        for (name, w) in wrapper.fileWrappers?[assetsName]?.fileWrappers ?? [:] where isSafeAssetName(name) {
            if let data = w.regularFileContents { assets[name] = data }
        }
        // Reading upgrades to v4; the next write is always v4.
        var doc = SketchDocument(formatVersion: 4, objects: body.objects,
                                 viewport: body.viewport, assets: assets, parts: parts, groups: body.groups ?? [])
        // Dangling or stale attachments (older builds, external edits): ends follow their connector or go free.
        let fixed = reconcileWires(in: doc)
        if !fixed.isEmpty { _ = SceneEdit.replace(fixed).apply(to: &doc) }
        // Dangling joint anchors and group members: repaired, not rejected.
        for edit in jointIntegrityEdits(in: doc) { _ = edit.apply(to: &doc) }
        return doc
    }

    /// Rejects values that would trap or exhaust memory downstream (index cells, layer sizes).
    private static let maxCoordinate = 1e7

    private static func validate(_ objects: [SceneObject], _ viewport: Viewport,
                                 _ parts: [String: PartDefinition]) throws {
        func coord(_ v: Double) -> Bool { v.isFinite && abs(v) <= maxCoordinate }
        func vec(_ p: Vec2) -> Bool { coord(p.x) && coord(p.y) }
        func size(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= maxCoordinate }
        for o in objects {
            let ok: Bool
            switch o {
            case .ink(let s): ok = s.points.allSatisfy { vec($0.position) } && size(s.baseWidth)
            case .shape(let s): ok = vec(s.start) && vec(s.end) && size(s.lineWidth) && s.rotation.isFinite
            case .text(let t): ok = vec(t.position) && size(t.fontSize) && t.rotation.isFinite
            case .image(let i):
                ok = vec(i.frame.origin) && size(i.frame.size.x) && size(i.frame.size.y) && i.rotation.isFinite
            case .part(let p):
                ok = vec(p.center) && p.rotation.isFinite && p.legEnds.values.allSatisfy(vec)
            case .wire(let w):
                ok = vec(w.start.position) && vec(w.end.position) && w.bends.allSatisfy(vec) && size(w.width)
            case .joint(let j):
                let shape: Bool = switch j.kind {
                case .hinge: !j.anchors.isEmpty
                case .fixed: j.anchors.count == 1 && j.grounded
                }
                ok = shape && vec(j.position) && j.anchors.allSatisfy { vec($0.point) }
            }
            if !ok { throw DocumentError.corrupt("object \(o.id) has an out-of-range coordinate or size") }
        }
        for (key, d) in parts {
            let ok = vec(d.size) && d.size.x >= 0 && d.size.y >= 0
                && d.connectors.allSatisfy { c in
                    vec(c.position) && (c.leg.map { vec($0.origin) && vec($0.defaultEnd) && size($0.width) } ?? true)
                }
            if !ok { throw DocumentError.corrupt("part definition \(key) has an out-of-range coordinate or size") }
        }
        if !vec(viewport.center) { throw DocumentError.corrupt("viewport centre out of range") }
    }
}
