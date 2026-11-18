/// Asset names become file names inside the `.flysketch` package (`assets/<name>`) and arrive from untrusted input
/// (pasteboard, imported parts, synced library, opened documents). Safe = one path component of `[A-Za-z0-9._-]`,
/// not starting with `.` (so never `.`/`..` or hidden), at most 255 bytes.
public func isSafeAssetName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 255, name.utf8.first != UInt8(ascii: ".") else { return false }
    return name.utf8.allSatisfy { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == UInt8(ascii: ".") || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
    }
}

public enum AssetNameError: Error, Equatable {
    case unsafe(String)
}
