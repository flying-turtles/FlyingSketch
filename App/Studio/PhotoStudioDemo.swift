#if DEBUG
import SwiftUI
import UIKit
import PartsKit
import PhotoPartKit
import SketchCore

/// Simulator/screenshot hook: `-photoStudioDemo` opens the studio on a generated board photo.
/// An open editor claims it (and places the saved part); otherwise it is presented over the document browser.
/// `-photoStudioStep <n>` (see `PhotoPartStudioView`) also seeds the draft so later steps have content.
enum PhotoStudioDemo {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-photoStudioDemo") }
    private static var claimed = false

    /// True once, for whoever presents the demo first.
    static func claim() -> Bool {
        guard isRequested, !claimed else { return false }
        claimed = true
        return true
    }

    // MARK: Session

    static let imageSize = (width: 1200, height: 800)
    static let padPitch = 30.0
    static let padColumns = 10
    static let padRows: [Double] = [290, 510]
    private static var firstPadX: Double { Double(imageSize.width) / 2 - padPitch * Double(padColumns - 1) / 2 }

    static func makeSession() -> StudioSession {
        guard let source = try? SourceImage.load(boardPNG()) else { preconditionFailure("demo image must decode") }
        let session = StudioSession(source: source, cutout: VisionCutout())
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-photoStudioStep"), i + 1 < args.count, let step = Int(args[i + 1]) else {
            return session
        }
        if step >= StudioStep.scale.rawValue {
            // 30 px pad pitch = 2.54 mm.
            session.draft.scale = .width(mm: Double(imageSize.width) * 2.54 / padPitch)
        }
        if step >= StudioStep.pins.rawValue { seedPins(&session.draft, duplicateName: step == StudioStep.pins.rawValue) }
        if step >= StudioStep.details.rawValue {
            session.draft.metadata.title = "Demo breakout"
            session.draft.metadata.tags = ["demo", "breakout"]
            session.draft.metadata.properties = ["pitch": "2.54 mm"]
        }
        return session
    }

    private static func seedPins(_ draft: inout PhotoPartDraft, duplicateName: Bool) {
        draft.gridSnap = false // rows are not a whole number of pitches apart
        for y in padRows {
            for c in 0..<padColumns { draft.addPin(atOutput: Vec2(x: firstPadX + Double(c) * padPitch, y: y)) }
        }
        draft.gridSnap = true
        draft.pins[0].role = .power
        draft.pins[1].role = .ground
        draft.pins[2].role = .i2cSDA
        draft.pins[3].role = .i2cSCL
        if duplicateName { draft.pins[5].name = "P5" } // shows the pin error flag
        draft.buses = [[draft.pins[10].id, draft.pins[11].id]]
    }

    /// 1200×800: grey background, green rounded board, two rows of gold pads.
    static func boardPNG() -> Data {
        let size = CGSize(width: imageSize.width, height: imageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { r in
            let ctx = r.cgContext
            ctx.setFillColor(UIColor(white: 0.62, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let board = CGRect(x: 200, y: 230, width: 800, height: 340)
            ctx.setFillColor(UIColor(red: 0.08, green: 0.42, blue: 0.2, alpha: 1).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: board, cornerRadius: 28).cgPath)
            ctx.fillPath()
            ctx.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 520, y: 350, width: 160, height: 100)) // chip
            ctx.setFillColor(UIColor(red: 0.85, green: 0.68, blue: 0.22, alpha: 1).cgColor)
            for y in padRows {
                for c in 0..<padColumns {
                    let x = firstPadX + Double(c) * padPitch
                    ctx.fillEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
                }
            }
        }
        guard let png = image.pngData() else { preconditionFailure("demo image must encode") }
        return png
    }

    // MARK: Presentation over the document browser

    private final class HostBox { weak var controller: UIViewController? }

    /// Waits briefly for an editor to claim the demo; otherwise presents it over the top view controller (library save only).
    static func presentOverRootIfUnclaimed(parts: PartsLibraryProvider) {
        guard isRequested else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard claim() else { return }
            var library = parts.library
            while library == nil {
                try? await Task.sleep(for: .milliseconds(100))
                library = parts.library
            }
            guard let library, let top = topViewController() else { return }
            let box = HostBox()
            let studio = PhotoPartStudioView(
                session: makeSession(), library: library,
                onSave: { _ in box.controller?.dismiss(animated: true) },
                onCancel: { box.controller?.dismiss(animated: true) })
            let host = UIHostingController(rootView: studio)
            host.modalPresentationStyle = .fullScreen
            box.controller = host
            top.present(host, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
#endif
