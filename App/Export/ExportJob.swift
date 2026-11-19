import ExportKit
import Foundation
import SketchCore

/// Serialises export jobs: at most one renders at a time; a job waits for its predecessor (which, if cancelled, stops at its next checkpoint).
actor ExportQueue {
    static let shared = ExportQueue()
    private var tail: Task<Void, Never>?

    func run(_ request: ExportRequest, document: SketchDocument, baseName: String,
             sizeLine: @escaping @Sendable @MainActor (String) -> Void) async throws -> URL {
        let previous = tail
        let job = Task.detached {
            await previous?.value
            try Task.checkCancellation()
            return try await ExportJob.execute(request, document: document, baseName: baseName, sizeLine: sizeLine)
        }
        tail = Task { _ = await job.result }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

enum ExportJob {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var lastDirectory: URL?

    /// Publishes the size line (fast), renders `request`, and writes it to a fresh temp directory; the previous export directory is removed.
    /// Call through `ExportQueue` so renders never overlap.
    nonisolated static func execute(_ request: ExportRequest, document: SketchDocument, baseName: String,
                                    sizeLine publish: @Sendable @MainActor (String) -> Void) async throws -> URL {
        func publishLine(_ line: String) async throws {
            try Task.checkCancellation()
            await publish(line)
        }
        let data: Data
        switch request.format {
        case .png:
            let content = try ExportContent.make(document, scope: request.scope)
            let plan = try RasterExporter.plan(content, options: request.png)
            var line = "\(plan.width) × \(plan.height) px"
            if plan.effectiveDPI < request.png.dpi { line += " (reduced to \(Int(plan.effectiveDPI.rounded(.down))) dpi)" }
            try await publishLine(line)
            try Task.checkCancellation()
            data = try RasterExporter.png(content, options: request.png).data
        case .pdf:
            let content = try ExportContent.make(document, scope: request.scope)
            try await publishLine(mmLine(content))
            try Task.checkCancellation()
            data = try PDFExporter.pdf(content)
        case .svg:
            let content = try ExportContent.make(document, scope: request.scope)
            try await publishLine(mmLine(content))
            try Task.checkCancellation()
            data = SVGWriter.svg(content)
        case .bom:
            try Task.checkCancellation()
            data = Data(BOMExporter.csv(document).utf8)
        case .netlist:
            try Task.checkCancellation()
            data = Data(NetlistExporter.csv(document).utf8)
        }
        try Task.checkCancellation()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(request, baseName: baseName))
        do {
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
        } catch {
            // A failed or cancelled job removes only its own directory; the newer job's is never touched.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let previous = lock.withLock { () -> URL? in
            defer { lastDirectory = dir }
            return lastDirectory
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }
        return url
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
