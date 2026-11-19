import ExportKit
import SketchCore

nonisolated enum ExportFormat: String, CaseIterable, Identifiable {
    case png, pdf, svg, bom, netlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "Image (PNG)"
        case .pdf: "PDF"
        case .svg: "SVG"
        case .bom: "Bill of Materials (CSV)"
        case .netlist: "Netlist (CSV)"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .pdf: "pdf"
        case .svg: "svg"
        case .bom, .netlist: "csv"
        }
    }

    /// BOM and netlist always cover the whole document.
    var usesScope: Bool {
        switch self {
        case .png, .pdf, .svg: true
        case .bom, .netlist: false
        }
    }
}

nonisolated struct ExportRequest: Hashable, Sendable {
    var format: ExportFormat
    var scope: ExportScope
    var png: PNGOptions
}
