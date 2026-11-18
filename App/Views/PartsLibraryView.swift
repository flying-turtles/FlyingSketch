import SwiftUI
import UniformTypeIdentifiers
import SketchCore
import PartsKit
import CanvasUI

/// Sheet listing library parts grouped by family; tap places a part, "Import .fzpz…" adds a personal part.
struct PartsLibraryView: View {
    let place: (LibraryPart) -> Void
    /// Called after a successful import (library contents changed).
    var libraryChanged: () -> Void = {}
    @Environment(PartsLibraryProvider.self) private var provider
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var parts: [LibraryPart]?
    @State private var issueCount = 0
    @State private var importing = false
    @State private var importError: String?
    /// In-flight import; cancelled when the sheet goes away.
    @State private var importTask: Task<Void, Never>?
    /// Bumped after an import so the list reloads.
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Parts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import .fzpz…") { importing = true }.disabled(provider.library == nil)
                    }
                }
        }
        .searchable(text: $query, prompt: "Search parts")
        .task(id: LoadKey(ready: provider.library != nil, query: query, generation: generation)) { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "fzpz") ?? .zip]) { result in
            importTask?.cancel()
            importTask = Task { await importPart(result) }
        }
        .onDisappear { importTask?.cancel() }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private struct LoadKey: Equatable {
        var ready: Bool
        var query: String
        var generation: Int
    }

    @ViewBuilder private var content: some View {
        if let parts {
            List {
                ForEach(groups(parts), id: \.family) { group in
                    Section(group.family) {
                        ForEach(group.parts, id: \.definition.key) { part in
                            Button {
                                place(part)
                                dismiss()
                            } label: {
                                PartRow(part: part)
                            }
                        }
                    }
                }
                if issueCount > 0 {
                    Section {} footer: {
                        Text("\(issueCount) personal part folder(s) could not be loaded.")
                    }
                }
            }
            .overlay {
                if parts.isEmpty { ContentUnavailableView.search(text: query) }
            }
        } else {
            ProgressView("Loading parts…")
        }
    }

    private func groups(_ parts: [LibraryPart]) -> [(family: String, parts: [LibraryPart])] {
        let byFamily = Dictionary(grouping: parts) { $0.definition.family.isEmpty ? "Other" : $0.definition.family }
        return byFamily.keys.sorted().map { ($0, byFamily[$0]!) }
    }

    private func load() async {
        guard let library = provider.library else { return }
        let found = await library.search(query)
        issueCount = await library.lastLoadIssues.count
        parts = found
    }

    private func importPart(_ result: Result<URL, Error>) async {
        guard let library = provider.library else { return }
        do {
            let url = try result.get()
            let data = try await Self.read(url)
            try Task.checkCancellation()
            _ = try await library.importFzpz(data)
            try Task.checkCancellation()
            generation += 1
            libraryChanged()
        } catch is CancellationError {
            return
        } catch {
            importError = String(describing: error)
        }
    }

    /// Reads a picked (security-scoped) file off the main actor.
    @concurrent private static func read(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

/// Title + thumbnail; the thumbnail renders off main once per part and is cached in memory.
private struct PartRow: View {
    let part: LibraryPart
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(decorative: image, scale: ThumbnailCache.scale).resizable().scaledToFit()
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(width: ThumbnailCache.side, height: ThumbnailCache.side)
            Text(part.definition.title).foregroundStyle(.primary)
        }
        .task(id: part.definition.key) { image = await ThumbnailCache.shared.image(for: part) }
    }
}

/// In-memory thumbnail cache keyed by definition key.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Thumbnail side in points; rendered at `scale` pixels per point.
    static let side: CGFloat = 44
    static let scale: CGFloat = 2

    private let cache = NSCache<NSString, CGImageBox>()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func image(for part: LibraryPart) async -> CGImage? {
        let key = part.definition.key as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let image = await PartThumbnail.render(part.graphic, definition: part.definition,
                                                     maxPixels: Int(Self.side * Self.scale)) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }
}
