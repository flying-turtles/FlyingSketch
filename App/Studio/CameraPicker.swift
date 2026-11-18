import SwiftUI
import UIKit

/// `UIImagePickerController` camera capture. Calls `onFinish` exactly once: the JPEG (quality 0.95) of the original
/// photo, `.cancelled`, or `.failed` when the photo can't be read or encoded. Check `CameraPicker.isAvailable` before presenting.
struct CameraPicker: UIViewControllerRepresentable {
    enum Outcome: Equatable {
        case photo(Data)
        case cancelled
        case failed
    }

    let onFinish: (Outcome) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onFinish: (Outcome) -> Void
        private var finished = false

        init(onFinish: @escaping (Outcome) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !finished else { return }
            finished = true
            guard let image = info[.originalImage] as? UIImage else { onFinish(.failed); return }
            let finish = onFinish
            Task {
                let data = await Self.jpeg(image)
                finish(data.map(Outcome.photo) ?? .failed)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            onFinish(.cancelled)
        }

        /// JPEG encoding of a full-resolution photo runs off the main actor.
        @concurrent private static func jpeg(_ image: UIImage) async -> Data? { image.jpegData(compressionQuality: 0.95) }
    }
}
