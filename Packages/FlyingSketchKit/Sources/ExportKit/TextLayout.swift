import CoreText
import Foundation
import SketchCore

enum TextLayout {
    static func font(size: Double) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// Lines of `t` with baselines relative to `position`, before rotation (y-down).
    static func lines(_ t: TextObject) -> [(text: String, baselineY: Double)] {
        let f = font(size: t.fontSize)
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f), leading = CTFontGetLeading(f)
        let pitch = ascent + descent + leading
        let parts = t.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        return parts.enumerated().map { (text: $0.element, baselineY: ascent + Double($0.offset) * pitch) }
    }

    /// Measured size (mm) of the unrotated text block with `position` as top-left.
    static func measuredSize(_ t: TextObject) -> Vec2 {
        let f = font(size: t.fontSize)
        let attrs: [CFString: Any] = [kCTFontAttributeName: f]
        var width = 0.0
        for line in lines(t) where !line.text.isEmpty {
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, attrs as CFDictionary)!
            width = max(width, CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
        }
        let last = lines(t).last?.baselineY ?? CTFontGetAscent(f)
        return Vec2(x: width, y: last + CTFontGetDescent(f))
    }
}
