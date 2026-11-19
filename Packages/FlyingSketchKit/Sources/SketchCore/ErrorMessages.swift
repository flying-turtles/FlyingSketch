import Foundation

// User-facing text for SketchCore errors (shown via `localizedDescription` in alerts).

extension DocumentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingDocumentJSON: "The document is missing its document.json."
        case .unsupportedVersion(let v): "The document needs a newer FlyingSketch (format \(v))."
        case .corrupt(let detail): "The document is damaged: \(detail)."
        }
    }
}

extension AssetNameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafe(let name): "Unsafe file name “\(name)”."
        }
    }
}

extension PartDefinitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .geometryOutOfRange: "The part's size or pin positions are out of range."
        case .unsafeGraphicAsset: "The part's graphic has an unsafe file name."
        }
    }
}
