import Foundation

/// One `Tools/catalog-manifest.json` entry.
struct ManifestEntry: Decodable {
    enum Source: String, Decodable {
        case fritzingParts = "fritzing-parts"
        case adafruit
        case custom
    }

    var source: Source
    /// `.fzp` path relative to the source root (`.fzpz` for `adafruit`).
    var fzp: String
    /// Catalog id (file name of `parts/<id>.json`).
    var id: String
}

extension ManifestEntry.Source {
    var repositoryURL: String? {
        switch self {
        case .fritzingParts: "https://github.com/fritzing/fritzing-parts"
        case .adafruit: "https://github.com/adafruit/Fritzing-Library"
        case .custom: nil
        }
    }
}
