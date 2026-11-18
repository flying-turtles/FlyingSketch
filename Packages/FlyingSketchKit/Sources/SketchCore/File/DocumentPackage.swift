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
    }

    public static func fileWrapper(for doc: SketchDocument) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = Body(formatVersion: doc.formatVersion, objects: doc.objects, viewport: doc.viewport)
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
            if version > 1 { throw DocumentError.unsupportedVersion(version) }
            body = try decoder.decode(Body.self, from: json)
        } catch let e as DocumentError {
            throw e
        } catch {
            throw DocumentError.corrupt(String(describing: error))
        }

        try validate(body.objects, body.viewport)

        var assets: [String: Data] = [:]
        for (name, w) in wrapper.fileWrappers?[assetsName]?.fileWrappers ?? [:] {
            if let data = w.regularFileContents { assets[name] = data }
        }
        return SketchDocument(formatVersion: body.formatVersion, objects: body.objects,
                              viewport: body.viewport, assets: assets)
    }

    /// Rejects values that would trap or exhaust memory downstream (index cells, layer sizes).
    private static let maxCoordinate = 1e7

    private static func validate(_ objects: [SceneObject], _ viewport: Viewport) throws {
        func coord(_ v: Double) -> Bool { v.isFinite && abs(v) <= maxCoordinate }
        func vec(_ p: Vec2) -> Bool { coord(p.x) && coord(p.y) }
        func size(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= maxCoordinate }
        for o in objects {
            let ok: Bool
            switch o {
            case .ink(let s): ok = s.points.allSatisfy { vec($0.position) } && size(s.baseWidth)
            case .shape(let s): ok = vec(s.start) && vec(s.end) && size(s.lineWidth)
            case .text(let t): ok = vec(t.position) && size(t.fontSize) && t.rotation.isFinite
            case .image(let i):
                ok = vec(i.frame.origin) && size(i.frame.size.x) && size(i.frame.size.y) && i.rotation.isFinite
            }
            if !ok { throw DocumentError.corrupt("object \(o.id) has an out-of-range coordinate or size") }
        }
        if !vec(viewport.center) { throw DocumentError.corrupt("viewport centre out of range") }
    }
}
