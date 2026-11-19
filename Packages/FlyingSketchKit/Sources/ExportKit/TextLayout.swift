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
        let parts = t.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parts.enumerated().map { (text: $0.element, baselineY: ascent + Double($0.offset) * pitch) }
    }
}
