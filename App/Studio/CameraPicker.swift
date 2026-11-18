import SwiftUI
import UIKit

/// `UIImagePickerController` camera capture. Calls `onFinish` once: JPEG (quality 0.95) of the original photo, or nil on cancel.
/// Check `CameraPicker.isAvailable` before presenting.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

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
        var onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { onFinish(nil); return }
            let finish = onFinish
            Task { finish(await Self.jpeg(image)) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }

        /// JPEG encoding of a full-resolution photo runs off the main actor.
        @concurrent private static func jpeg(_ image: UIImage) async -> Data? { image.jpegData(compressionQuality: 0.95) }
    }
}
