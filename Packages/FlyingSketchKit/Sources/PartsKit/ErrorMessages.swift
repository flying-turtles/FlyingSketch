import Foundation

// User-facing text for PartsKit errors (shown via `localizedDescription` in alerts).

extension PersonalLibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .escapesRoot:
            "The part's library ID can't be used as a folder name."
        case .invalidStudioFile(let name):
            "Unexpected photo-studio file “\(name)”."
        case .notPersonal:
            "Only parts in your personal library can be changed or deleted."
        case .studioDownloading:
            "The part's editing files are still downloading from iCloud. Try again in a moment."
        }
    }
}

extension SVGError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSVG: "The graphic isn't an SVG file."
        case .missingSize: "The SVG has no absolute width and height."
        case .unsupported(let what): "Unsupported SVG: \(what)."
        }
    }
}

extension ZipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZip: "The file isn't a valid .fzpz (ZIP) archive."
        case .unsupportedMethod(let method): "The archive uses unsupported compression (method \(method))."
        case .corrupt(let detail): "The archive is damaged: \(detail)."
        case .tooLarge(let detail): "The archive is too large: \(detail)."
        case .unsafePath(let path): "The archive contains an unsafe path: \(path)."
        }
    }
}

extension PartImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noFzp: "The file contains no part definition (.fzp)."
        case .multipleFzp: "The file contains more than one part definition (.fzp)."
        case .missingBreadboardSVG(let name): "The breadboard graphic “\(name)” is missing."
        case .missingConnectorGeometry(let id): "Connector “\(id)” has no position in the breadboard graphic."
        case .invalidFzp(let detail): "The part definition is invalid: \(detail)."
        case .invalidSVG(let detail): "The breadboard graphic is invalid: \(detail)."
        case .invalidArchive(let detail): "The archive is invalid: \(detail)."
        }
    }
}
