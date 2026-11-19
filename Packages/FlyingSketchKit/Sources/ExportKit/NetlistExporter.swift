import Foundation
import SketchCore
import NetKit

public enum NetlistExporter {
    public static func csv(_ doc: SketchDocument) -> String {
        var labels: [ObjectID: (instance: PartInstance, def: PartDefinition)] = [:]
        for case .part(let p) in doc.objects {
            if let def = doc.parts[p.definitionKey] { labels[p.id] = (p, def) }
        }
        var rows = [["Net", "Pins"]]
        for net in nets(in: doc) {
            var pins = Set<String>()
            for ref in net.members {
                guard let (inst, def) = labels[ref.part], def.family.lowercased() != "breadboard" else { continue }
                let label = inst.label.isEmpty ? def.title : inst.label
                let rawName = def.connectors.first { $0.id == ref.connector }?.name ?? ""
                pins.insert("\(label).\(rawName.isEmpty ? ref.connector : rawName)")
            }
            guard pins.count >= 2 else { continue }
            rows.append([net.name, pins.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: " ")])
        }
        return CSV.document(rows)
    }
}
