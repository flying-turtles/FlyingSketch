import Foundation
import Observation
import PartsKit
import SketchCore

public enum StudioStep: Int, CaseIterable, Sendable { case cutout, refine, crop, scale, pins, details }

public enum CutoutState: Equatable, Sendable {
    case idle, running, choosing(count: Int), done, failed(PhotoPartError)
}

@MainActor @Observable
public final class StudioSession {
    public static let maxUndo = 20

    public private(set) var source: SourceImage
    public var draft: PhotoPartDraft
    public private(set) var mask: MaskBitmap {
        didSet { maskIsEmpty = mask.boundingBox == nil }
    }
    /// Cached `mask.boundingBox == nil`, so `blockingError` doesn't scan the bitmap on every view update.
    public private(set) var maskIsEmpty: Bool
    public var step: StudioStep = .cutout
    public private(set) var cutoutState: CutoutState = .idle
    public private(set) var instances: [MaskBitmap] = []
    private var _brushRadius: Double = 24
    /// Clamped to 2...200.
    public var brushRadius: Double {
        get { _brushRadius }
        set { _brushRadius = min(max(newValue, 2), 200) }
    }
    public var brushAdds: Bool = true

    private var undoStack: [MaskBitmap] = []
    private var redoStack: [MaskBitmap] = []
    private let cutout: CutoutProviding
    private var runToken = 0

    /// A `mask` whose size differs from `source.pixelSize` is ignored (full mask instead).
    /// A valid stored `mask` (re-edit) is kept: `cutoutState` starts `.done` (no auto cutout) and `step` at `.pins`.
    public init(source: SourceImage, cutout: CutoutProviding, draft: PhotoPartDraft? = nil, mask: MaskBitmap? = nil) {
        self.source = source
        self.cutout = cutout
        self.draft = draft ?? PhotoPartDraft(sourceSize: source.pixelSize)
        let full = MaskBitmap(width: source.pixelSize.width, height: source.pixelSize.height, filled: true)
        let initial: MaskBitmap
        if let mask, mask.width == full.width, mask.height == full.height {
            initial = mask
            cutoutState = .done
            step = .pins
        } else {
            initial = full
        }
        self.mask = initial
        maskIsEmpty = initial.boundingBox == nil
    }

    // MARK: Cutout

    public func runAutoCutout() async {
        runToken += 1
        let token = runToken
        cutoutState = .running
        instances = []
        do {
            let found = try await cutout.instances(in: source)
            guard token == runToken else { return }
            if found.isEmpty {
                cutoutState = .failed(.noForeground)
            } else if found.count == 1 {
                instances = found
                apply(found[0])
                cutoutState = .done
            } else {
                instances = found
                cutoutState = .choosing(count: found.count)
            }
        } catch {
            guard token == runToken else { return }
            instances = []
            cutoutState = .failed(error)
        }
    }

    public func chooseInstance(at sourcePoint: Vec2) {
        guard case .choosing = cutoutState,
              let i = instanceIndex(at: sourcePoint, in: instances) else { return }
        apply(instances[i])
        cutoutState = .done
    }

    public func chooseAllInstances() {
        guard case .choosing = cutoutState, var union = instances.first else { return }
        for m in instances.dropFirst() { try? union.formUnion(m) }
        apply(union)
        cutoutState = .done
    }

    public func useWholePhoto() {
        runToken += 1
        apply(MaskBitmap(width: source.pixelSize.width, height: source.pixelSize.height, filled: true))
        cutoutState = .done
    }

    // MARK: Mask editing

    public func applyTrace(_ sourcePoints: [Vec2]) throws(PhotoPartError) {
        var next = mask
        try next.fillPolygon(sourcePoints)
        apply(next)
    }

    public func applyBrush(_ sourcePoints: [Vec2]) {
        guard !sourcePoints.isEmpty else { return }
        var next = mask
        next.stroke(sourcePoints, radius: brushRadius, add: brushAdds)
        guard next != mask else { return }
        apply(next)
    }

    public var canUndoMask: Bool { !undoStack.isEmpty }
    public var canRedoMask: Bool { !redoStack.isEmpty }

    public func undoMask() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(mask)
        mask = prev
    }

    public func redoMask() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(mask)
        mask = next
    }

    private func apply(_ new: MaskBitmap) {
        undoStack.append(mask)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst(undoStack.count - Self.maxUndo) }
        redoStack.removeAll()
        mask = new
    }

    // MARK: Validation / output

    public var blockingError: PhotoPartError? {
        if maskIsEmpty { return .emptyMask }
        do { try PhotoPartBuilder.validate(draft) } catch { return error }
        return nil
    }

    public func build() throws(PhotoPartError) -> LibraryPart {
        try snapshot().build()
    }

    public func studioFiles() -> StudioFiles {
        snapshot().studioFiles()
    }

    /// Value copy of what `build()` / `studioFiles()` need, for building off the main actor.
    public func snapshot() -> StudioSnapshot {
        StudioSnapshot(source: source, mask: mask, draft: draft)
    }
}

/// Sendable inputs of a save; `build()` and `studioFiles()` are pure and may run on any thread.
public struct StudioSnapshot: Sendable {
    public var source: SourceImage
    public var mask: MaskBitmap
    public var draft: PhotoPartDraft

    public func build() throws(PhotoPartError) -> LibraryPart {
        try PhotoPartBuilder.build(source: source, mask: mask, draft: draft)
    }

    public func studioFiles() -> StudioFiles {
        StudioFiles(draft: draft, sourcePNG: source.pngData(), maskPNG: mask.pngData())
    }
}

public struct StudioFiles: Sendable, Equatable {
    public var draft: PhotoPartDraft
    public var sourcePNG: Data
    public var maskPNG: Data

    public init(draft: PhotoPartDraft, sourcePNG: Data, maskPNG: Data) {
        self.draft = draft
        self.sourcePNG = sourcePNG
        self.maskPNG = maskPNG
    }

    public func encoded() throws -> [String: Data] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return ["draft.json": try enc.encode(draft), "source.png": sourcePNG, "mask.png": maskPNG]
    }

    /// `.undecodableImage` doubles as "unreadable studio data" (missing key, bad draft JSON, bad PNG, invalid draft).
    public static func decode(_ files: [String: Data]) throws(PhotoPartError) -> (SourceImage, MaskBitmap, PhotoPartDraft) {
        guard let draftData = files["draft.json"], let sourceData = files["source.png"],
              let maskData = files["mask.png"] else { throw .undecodableImage }
        guard let draft = try? JSONDecoder().decode(PhotoPartDraft.self, from: draftData),
              isStructurallyValid(draft) else {
            throw .undecodableImage
        }
        let source = try SourceImage.load(sourceData)
        guard draft.sourceSize == source.pixelSize else { throw .maskSizeMismatch }
        let mask = try MaskBitmap.decode(png: maskData, expected: source.pixelSize)
        return (source, mask, draft)
    }
}

extension StudioFiles {
    static let maxPinNumber = 100_000

    /// Rejects drafts the studio could never have written (tampered or corrupt `draft.json`).
    static func isStructurallyValid(_ d: PhotoPartDraft) -> Bool {
        func finite(_ v: Vec2) -> Bool { v.x.isFinite && v.y.isFinite }
        let c = d.crop
        guard (0...3).contains(c.quarterTurns), c.angle.isFinite, abs(c.angle) <= .pi / 4 + 1e-9,
              finite(c.center), finite(c.size), c.size.x > 0, c.size.y > 0 else { return false }
        switch d.scale {
        case nil: break
        case let .twoPoints(a, b, mm)?: guard finite(a), finite(b), mm.isFinite else { return false }
        case let .width(mm)?: guard mm.isFinite else { return false }
        }
        let ids = d.pins.map(\.id)
        guard Set(ids).count == ids.count, d.pins.allSatisfy({ finite($0.position) }) else { return false }
        guard d.nextPinNumber >= 0, d.nextPinNumber <= maxPinNumber else { return false }
        for id in ids {
            guard id.hasPrefix("connector"), let n = Int(id.dropFirst("connector".count)) else { continue }
            guard n < d.nextPinNumber else { return false }
        }
        let idSet = Set(ids)
        return d.buses.allSatisfy { $0.allSatisfy(idSet.contains) }
    }
}
