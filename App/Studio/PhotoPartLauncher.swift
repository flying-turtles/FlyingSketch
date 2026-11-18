import Foundation
import PartsKit
import PhotoPartKit

/// A studio to present: a new photo part, or an existing personal part re-opened with its draft (same `libraryID`).
struct StudioLaunch: Identifiable {
    let id = UUID()
    let session: StudioSession
    let isEdit: Bool
}

/// Builds studio sessions for the parts library. Image and studio-file decoding run off the main actor.
enum PhotoPartLauncher {
    enum Failure: Error {
        case unreadablePhoto
        case notEditable

        var message: String {
            switch self {
            case .unreadablePhoto: "Could not read photo"
            case .notEditable: "This part can't be edited"
            }
        }
    }

    /// New part from camera/Photos bytes.
    static func newPart(from data: Data) async throws(Failure) -> StudioLaunch {
        let source: SourceImage
        do { source = try await loadSource(data) } catch { throw .unreadablePhoto }
        return StudioLaunch(session: StudioSession(source: source, cutout: VisionCutout()), isEdit: false)
    }

    /// Re-opens a personal photo part from its stored studio files.
    static func edit(_ part: LibraryPart, in library: PartsLibrary) async throws(Failure) -> StudioLaunch {
        guard part.source == .personal, part.isEditable else { throw .notEditable }
        let decoded: (SourceImage, MaskBitmap, PhotoPartDraft)
        do {
            guard let files = try await library.studioFiles(libraryID: part.definition.libraryID) else { throw Failure.notEditable }
            decoded = try await decodeStudio(files)
        } catch {
            throw .notEditable
        }
        let (source, mask, draft) = decoded
        return StudioLaunch(session: StudioSession(source: source, cutout: VisionCutout(), draft: draft, mask: mask),
                            isEdit: true)
    }

    @concurrent private static func loadSource(_ data: Data) async throws(PhotoPartError) -> SourceImage {
        try SourceImage.load(data)
    }

    @concurrent private static func decodeStudio(_ files: [String: Data]) async throws(PhotoPartError)
        -> (SourceImage, MaskBitmap, PhotoPartDraft) {
        try StudioFiles.decode(files)
    }
}
