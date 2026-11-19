import ExportKit
import Foundation
import SketchCore

enum ExportJob {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var lastDirectory: URL?

    /// Renders `request` and writes it to a fresh temp directory; the previous export directory is removed.
    @concurrent static func run(_ request: ExportRequest, document: SketchDocument, baseName: String) async throws -> (url: URL, sizeLine: String?) {
        let data: Data
        var sizeLine: String?
        switch request.format {
        case .png:
            let content = try ExportContent.make(document, scope: request.scope)
            let plan = try RasterExporter.plan(content, options: request.png)
            var line = "\(plan.width) × \(plan.height) px"
            if plan.effectiveDPI < request.png.dpi { line += " (reduced to \(Int(plan.effectiveDPI.rounded(.down))) dpi)" }
            sizeLine = line
            data = try RasterExporter.png(content, options: request.png).data
        case .pdf:
            let content = try ExportContent.make(document, scope: request.scope)
            sizeLine = mmLine(content)
            data = try PDFExporter.pdf(content)
        case .svg:
            let content = try ExportContent.make(document, scope: request.scope)
            sizeLine = mmLine(content)
            data = SVGWriter.svg(content)
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
        return (url, sizeLine)
    }

    nonisolated private static func mmLine(_ content: ExportContent) -> String {
        "\(Int(content.bounds.size.x.rounded())) × \(Int(content.bounds.size.y.rounded())) mm"
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
