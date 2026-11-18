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

        var assets: [String: Data] = [:]
        for (name, w) in wrapper.fileWrappers?[assetsName]?.fileWrappers ?? [:] {
            if let data = w.regularFileContents { assets[name] = data }
        }
        return SketchDocument(formatVersion: body.formatVersion, objects: body.objects,
                              viewport: body.viewport, assets: assets)
    }
}
