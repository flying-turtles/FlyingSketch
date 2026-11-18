import CoreGraphics
import Foundation

/// LRU cache of rasterized part graphics keyed by `(graphicAsset, scaleBucket)`.
/// `bucket` is the power-of-two exponent of the raster scale in pixels per mm (scale = 2^bucket).
final class PartRasterCache {
    struct Key: Hashable {
        var asset: String
        var bucket: Int
    }

    private struct Entry {
        var image: CGImage
        var bytes: Int
        var tick: Int
    }

    static let defaultByteBudget = 64 * 1024 * 1024

    let byteBudget: Int
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private(set) var totalBytes = 0

    init(byteBudget: Int = PartRasterCache.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    var count: Int { entries.count }

    /// Smallest power-of-two exponent whose scale (px/mm) is at least `pixelsPerMM`.
    static func bucket(forPixelsPerMM pixelsPerMM: Double) -> Int {
        Int(Foundation.ceil(Foundation.log2(max(pixelsPerMM, 1e-6))))
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// Returns the image and marks it most recently used.
    func image(for key: Key) -> CGImage? {
        guard var e = entries[key] else { return nil }
        clock += 1
        e.tick = clock
        entries[key] = e
        return e.image
    }

    /// Any cached image of `asset` (highest bucket first); a blurry stand-in while the right bucket renders.
    func anyImage(forAsset asset: String) -> CGImage? {
        let best = entries.filter { $0.key.asset == asset }.max { $0.key.bucket < $1.key.bucket }
        return best?.value.image
    }

    func insert(_ image: CGImage, for key: Key) {
        if let old = entries[key] { totalBytes -= old.bytes }
        clock += 1
        let bytes = image.width * image.height * 4
        entries[key] = Entry(image: image, bytes: bytes, tick: clock)
        totalBytes += bytes
        while totalBytes > byteBudget, entries.count > 1,
              let victim = entries.filter({ $0.key != key }).min(by: { $0.value.tick < $1.value.tick }) {
            totalBytes -= victim.value.bytes
            entries[victim.key] = nil
        }
    }
}
