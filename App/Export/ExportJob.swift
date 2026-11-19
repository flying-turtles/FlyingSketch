import ExportKit
import Foundation
import SketchCore

enum ExportJob {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var lastDirectory: URL?

    /// Renders `request` and writes it to a fresh temp directory; the previous export directory is removed.
    @concurrent static func run(_ request: ExportRequest, document: SketchDocument, baseName: String) async throws -> URL {
        let data: Data
        switch request.format {
        case .png:
            let content = try ExportContent.make(document, scope: request.scope)
            data = try RasterExporter.png(content, options: request.png).data
        case .pdf:
            data = try PDFExporter.pdf(ExportContent.make(document, scope: request.scope))
        case .svg:
            data = SVGWriter.svg(try ExportContent.make(document, scope: request.scope))
        case .bom:
            data = Data(BOMExporter.csv(document).utf8)
        case .netlist:
            data = Data(NetlistExporter.csv(document).utf8)
        }
        try Task.checkCancellation()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(request, baseName: baseName))
        try data.write(to: url, options: .atomic)

        let previous = lock.withLock { () -> URL? in
            defer { lastDirectory = dir }
            return lastDirectory
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }
        return url
    }

    /// `<name>[ (selection)].ext`, `<name> BOM.csv`, `<name> Netlist.csv`; `/` and `:` become `-`.
    nonisolated static func fileName(_ request: ExportRequest, baseName: String) -> String {
        var name = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "Sketch" }
        switch request.format {
        case .png, .pdf, .svg:
            if case .selection = request.scope { name += " (selection)" }
        case .bom: name += " BOM"
        case .netlist: name += " Netlist"
        }
        return "\(name).\(request.format.fileExtension)"
    }
}
