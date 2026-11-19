enum CSV {
    /// Works on unicode scalars: `Character`s merge CRLF and combining sequences, hiding `\r`, `\n`, `"` and `,`.
    static func field(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard scalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        var out = String.UnicodeScalarView()
        out.append("\"")
        for c in scalars {
            if c == "\"" { out.append("\"") }
            out.append(c)
        }
        out.append("\"")
        return String(out)
    }

    /// UTF-8 BOM, comma separated, every row ends with CRLF.
    static func document(_ rows: [[String]]) -> String {
        "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
    }
}
