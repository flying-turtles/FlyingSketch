enum CSV {
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacing("\"", with: "\"\"") + "\""
    }

    /// UTF-8 BOM, comma separated, every row ends with CRLF.
    static func document(_ rows: [[String]]) -> String {
        "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
    }
}
