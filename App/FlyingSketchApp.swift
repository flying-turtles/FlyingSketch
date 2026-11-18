import SwiftUI
import PartsKit

@main
struct FlyingSketchApp: App {
    /// One parts library shared by every open document.
    @State private var parts = PartsLibraryProvider()

    var body: some Scene {
        DocumentGroup(newDocument: { SketchFileDocument() }) { file in
            SketchEditorView(document: file.document)
                .environment(parts)
        }
    }
}

/// Creates the shared `PartsLibrary` asynchronously (the personal root may resolve an iCloud container).
@Observable
final class PartsLibraryProvider {
    private(set) var library: PartsLibrary?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init() {
        loading = Task { [weak self] in
            guard let catalog = Bundle.main.url(forResource: "Catalog", withExtension: nil) else {
                preconditionFailure("Catalog folder missing from the app bundle")
            }
            let store = PersonalLibraryStore(rootURL: await PersonalLibraryStore.defaultRoot())
            self?.library = PartsLibrary(bundledCatalogURL: catalog, personalStore: store)
        }
    }
}
