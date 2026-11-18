import Foundation

// catalog-builder <manifest> <vendorDir> <customDir> <outDir>
let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write(Data("usage: catalog-builder <manifest> <vendorDir> <customDir> <outDir>\n".utf8))
    exit(2)
}
func url(_ p: String) -> URL { URL(fileURLWithPath: p).standardizedFileURL }

do {
    let entries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: url(args[1])))
    let ids = entries.map(\.id)
    if let dup = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
        throw BuildError("duplicate manifest id \(dup)")
    }
    let loader = PartLoader(vendorDir: url(args[2]), customDir: url(args[3]))
    var parts: [LoadedPart] = []
    var failures: [String] = []
    for e in entries {
        do { parts.append(try loader.load(e)) } catch { failures.append("\(e.id) (\(e.fzp)): \(error)") }
    }
    guard failures.isEmpty else {
        throw BuildError("\(failures.count) part(s) failed to import:\n  " + failures.joined(separator: "\n  "))
    }
    try CatalogWriter(outDir: url(args[4])).write(parts)
    print("catalog-builder: wrote \(parts.count) parts to \(args[4])")
} catch {
    FileHandle.standardError.write(Data("catalog-builder: error: \(error)\n".utf8))
    exit(1)
}
