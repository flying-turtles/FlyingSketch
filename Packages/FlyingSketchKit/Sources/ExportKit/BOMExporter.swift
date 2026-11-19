import Foundation
import SketchCore

public enum BOMExporter {
    public static func csv(_ doc: SketchDocument) -> String {
        struct Key: Hashable { var title: String; var properties: String }
        var groups: [Key: [String]] = [:]
        for case .part(let p) in doc.objects {
            let def = doc.parts[p.definitionKey]
            let title = def?.title ?? "Unknown part (\(p.definitionKey))"
            let merged = (def?.properties ?? [:]).merging(p.properties) { _, instance in instance }
            let props = merged
                .filter { $0.key.lowercased() != "family" && !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            groups[Key(title: title, properties: props), default: []].append(p.label)
        }
        let keys = groups.keys.sorted { ($0.title, $0.properties) < ($1.title, $1.properties) }
        var rows = [["Quantity", "Title", "Labels", "Properties"]]
        for k in keys {
            let labels = groups[k]!
            let sorted = labels.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            rows.append([String(labels.count), k.title, sorted.joined(separator: " "), k.properties])
        }
        return CSV.document(rows)
    }
}
