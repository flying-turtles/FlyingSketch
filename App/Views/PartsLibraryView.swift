import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SketchCore
import PartsKit
import CanvasUI
import PhotoPartKit

/// Sheet listing library parts grouped by family; tap places a part, "Import .fzpz…" adds a personal part,
/// "New Photo Part" opens the photo studio. Personal parts get Edit (photo parts) / Export / Delete context actions.
///
/// The studio is a `fullScreenCover` presented from this sheet. After saving a new part it is placed via `place`,
/// the studio closes, and this sheet dismisses itself in the cover's `onDismiss` (sequential, so the two
/// dismissals never race). Saving an edit keeps the library open.
struct PartsLibraryView: View {
    let place: (LibraryPart) -> Void
    /// Called after the library contents changed (import, photo-part save, delete).
    var libraryChanged: () -> Void = {}
    @Environment(PartsLibraryProvider.self) private var provider
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var parts: [LibraryPart]?
    @State private var issueCount = 0
    @State private var importing = false
    @State private var alert: AlertInfo?
    /// In-flight import / photo load / export / delete; cancelled when the sheet goes away.
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    /// Bumped after the library changed so the list reloads.
    @State private var generation = 0
    @State private var showsCamera = false
    /// Camera result, consumed when the camera cover has finished dismissing.
    @State private var cameraOutcome: CameraPicker.Outcome?
    @State private var choosingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var studio: StudioLaunch?
    @State private var dismissAfterStudio = false
    @State private var pendingDelete: LibraryPart?
    @State private var exportFile: FzpzFile?
    @State private var exporting = false

    private struct AlertInfo {
        var title: String
        var message: String
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Parts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { newPhotoPartMenu }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import .fzpz…") { importing = true }.disabled(provider.library == nil)
                    }
                }
                .disabled(busy)
                .overlay { if busy { ProgressView().controlSize(.large) } }
                .fullScreenCover(isPresented: $showsCamera, onDismiss: consumeCameraData) {
                    CameraPicker { outcome in
                        cameraOutcome = outcome
                        showsCamera = false
                    }
                    .ignoresSafeArea()
                }
                .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
                .onChange(of: photoItem) { loadPickedPhoto() }
        }
        .searchable(text: $query, prompt: "Search parts")
        .task(id: LoadKey(ready: provider.library != nil, query: query, generation: generation)) { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.fzpz]) { result in
            run { await importPart(result) }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .fzpz,
                      defaultFilename: exportFile?.filename) { result in
            exportFile = nil
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
            }
        }
        .confirmationDialog(pendingDelete.map { "Delete \($0.definition.title)?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { part in
            Button("Delete", role: .destructive) { run { await delete(part) } }
        }
        .fullScreenCover(item: $studio, onDismiss: studioDismissed) { launch in
            if let library = provider.library {
                PhotoPartStudioView(session: launch.session, library: library,
                                    onSave: { studioSaved($0, launch: launch) },
                                    onCancel: { studio = nil })
            }
        }
        .onDisappear { work?.cancel() }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private struct LoadKey: Equatable {
        var ready: Bool
        var query: String
        var generation: Int
    }

    private var newPhotoPartMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo…", systemImage: "camera") { showsCamera = true }
            }
            Button("Choose Photo…", systemImage: "photo.on.rectangle") { choosingPhoto = true }
        } label: {
            Label("New Photo Part", systemImage: "camera.viewfinder")
        }
        .disabled(provider.library == nil)
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
                            .contextMenu { if part.source == .personal { personalActions(part) } }
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

    @ViewBuilder private func personalActions(_ part: LibraryPart) -> some View {
        if part.isEditable {
            Button("Edit Photo Part…", systemImage: "pencil") { run { await edit(part) } }
        }
        Button("Export .fzpz…", systemImage: "square.and.arrow.up") { run { await export(part) } }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = part }
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

    /// Runs one piece of async work at a time with a progress overlay (replaces any in-flight work).
    private func run(_ operation: @escaping () async -> Void) {
        work?.cancel()
        busy = true
        work = Task {
            await operation()
            if !Task.isCancelled { busy = false }
        }
    }

    private func contentChanged() {
        generation += 1
        libraryChanged()
    }

    // MARK: Import

    private func importPart(_ result: Result<URL, Error>) async {
        guard let library = provider.library else { return }
        do {
            let url = try result.get()
            let data = try await Self.read(url)
            try Task.checkCancellation()
            _ = try await library.importFzpz(data)
            try Task.checkCancellation()
            contentChanged()
        } catch is CancellationError {
            return
        } catch {
            alert = AlertInfo(title: "Import failed", message: error.localizedDescription)
        }
    }

    /// Reads a picked (security-scoped) file off the main actor.
    @concurrent private static func read(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    // MARK: Photo parts

    private func consumeCameraData() {
        let outcome = cameraOutcome
        cameraOutcome = nil
        switch outcome {
        case .photo(let data)?: run { await openNewPart(data) }
        case .failed?: alert = AlertInfo(title: "Photo part", message: PhotoPartLauncher.Failure.unreadablePhoto.message)
        case .cancelled?, nil: break
        }
    }

    private func loadPickedPhoto() {
        guard let item = photoItem else { return }
        photoItem = nil
        run {
            let data: Data?
            do { data = try await item.loadTransferable(type: Data.self) } catch { data = nil }
            guard !Task.isCancelled else { return }
            guard let data else {
                alert = AlertInfo(title: "Photo part", message: PhotoPartLauncher.Failure.unreadablePhoto.message)
                return
            }
            await openNewPart(data)
        }
    }

    private func openNewPart(_ data: Data) async {
        do {
            let launch = try await PhotoPartLauncher.newPart(from: data)
            guard !Task.isCancelled else { return }
            studio = launch
        } catch {
            alert = AlertInfo(title: "Photo part", message: error.message)
        }
    }

    private func edit(_ part: LibraryPart) async {
        guard let library = provider.library else { return }
        do {
            let launch = try await PhotoPartLauncher.edit(part, in: library)
            guard !Task.isCancelled else { return }
            studio = launch
        } catch {
            alert = AlertInfo(title: "Photo part", message: error.message)
        }
    }

    /// The studio already saved the part (and its studio files) to the library.
    private func studioSaved(_ part: LibraryPart, launch: StudioLaunch) {
        contentChanged()
        if !launch.isEdit {
            place(part)
            dismissAfterStudio = true
        }
        studio = nil
    }

    private func studioDismissed() {
        guard dismissAfterStudio else { return }
        dismissAfterStudio = false
        dismiss()
    }

    // MARK: Export / delete

    private func export(_ part: LibraryPart) async {
        do {
            let data = try await Self.exportData(part)
            guard !Task.isCancelled else { return }
            exportFile = FzpzFile(data: data, filename: FzpzFile.filename(for: part.definition.title))
            exporting = true
        } catch is CancellationError {
            return
        } catch {
            alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
        }
    }

    @concurrent private static func exportData(_ part: LibraryPart) async throws -> Data {
        try FzpzExporter.export(part)
    }

    private func delete(_ part: LibraryPart) async {
        guard let library = provider.library else { return }
        do {
            try await library.delete(libraryID: part.definition.libraryID)
            contentChanged()
        } catch {
            alert = AlertInfo(title: "Delete failed", message: error.localizedDescription)
        }
    }
}

extension UTType {
    nonisolated static let fzpz = UTType(filenameExtension: "fzpz") ?? .zip
}

/// Exported `.fzpz` bytes for `fileExporter`.
nonisolated struct FzpzFile: FileDocument {
    static let readableContentTypes: [UTType] = [.fzpz]

    var data: Data
    var filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
        filename = configuration.file.filename ?? "Part.fzpz"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// `<title>.fzpz` with path separators, reserved and control characters replaced; "Part" when nothing is left.
    static func filename(for title: String) -> String {
        let reserved = Set("/\\:?%*|\"<>")
        let cleaned = String(title.map { reserved.contains($0) || ($0.asciiValue ?? 0x20) < 0x20 ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Part" : cleaned) + ".fzpz"
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
