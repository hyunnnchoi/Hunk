import Foundation

struct ParsedHunk: Sendable {
    let oldStart: Int
    let newStart: Int
    /// Function or section context git printed after the second `@@`.
    let context: String
    let lines: [DiffLine]
    /// Raw text including the `@@` line, newline-terminated. Nil when it isn't valid UTF-8.
    let text: String?
}

struct ParsedFile: Sendable {
    let oldPath: String?
    let newPath: String?
    /// Raw header lines before the first hunk, newline-terminated.
    let header: String
    let isBinary: Bool
    let isNew: Bool
    let isDeleted: Bool
    let isRename: Bool
    let isSubmodule: Bool
    let hunks: [ParsedHunk]
    var path: String { (isDeleted ? oldPath : newPath) ?? oldPath ?? "unknown" }
}

/// Parses `git diff` output produced with `a/` and `b/` prefixes.
enum DiffParser {
    static func parse(_ data: Data) -> [ParsedFile] {
        // Split on LF bytes: a Swift Character would swallow CRLF and corrupt patches.
        let rows = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        var files: [ParsedFile] = []
        var index = 0
        while index < rows.count {
            guard rows[index].starts(with: Data("diff --git ".utf8)) else { index += 1; continue }
            files.append(parseFile(rows, &index))
        }
        return files
    }

    private static func parseFile(_ rows: [Data], _ index: inout Int) -> ParsedFile {
        let gitLine = string(rows[index]); index += 1
        var header = [gitLine]
        var oldPath: String?, newPath: String?
        var isBinary = false, isNew = false, isDeleted = false, isRename = false, isSubmodule = false
        while index < rows.count {
            let row = rows[index]
            if row.starts(with: Data("@@ ".utf8)) || row.starts(with: Data("diff --git ".utf8)) { break }
            let line = string(row); index += 1
            if line.isEmpty && index == rows.count { break }
            header.append(line)
            if line.hasPrefix("--- ") { oldPath = path(fromMarker: String(line.dropFirst(4))) ?? oldPath }
            else if line.hasPrefix("+++ ") { newPath = path(fromMarker: String(line.dropFirst(4))) ?? newPath }
            else if line.hasPrefix("rename from ") { oldPath = unquote(String(line.dropFirst(12))); isRename = true }
            else if line.hasPrefix("rename to ") { newPath = unquote(String(line.dropFirst(10))); isRename = true }
            else if line.hasPrefix("new file mode") { isNew = true }
            else if line.hasPrefix("deleted file mode") { isDeleted = true }
            else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { isBinary = true }
            if line.contains("160000") && (line.hasPrefix("index ") || line.contains("mode")) { isSubmodule = true }
        }
        if oldPath == nil && newPath == nil, let both = paths(fromGitLine: gitLine) {
            oldPath = both; newPath = both
        }
        var hunks: [ParsedHunk] = []
        while index < rows.count, rows[index].starts(with: Data("@@ ".utf8)) {
            guard let hunk = parseHunk(rows, &index) else { break }
            hunks.append(hunk)
        }
        return ParsedFile(oldPath: oldPath, newPath: newPath, header: header.joined(separator: "\n") + "\n",
                          isBinary: isBinary, isNew: isNew, isDeleted: isDeleted, isRename: isRename,
                          isSubmodule: isSubmodule, hunks: hunks)
    }

    private static func parseHunk(_ rows: [Data], _ index: inout Int) -> ParsedHunk? {
        let head = string(rows[index])
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@ context
        let parts = head.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"), parts[3] == "@@",
              let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else { return nil }
        let context = parts.count > 4 ? String(parts[4]) : ""
        var raw = [rows[index]]; index += 1
        var lines: [DiffLine] = []
        var oldLeft = old.count, newLeft = new.count
        var oldNumber = old.start, newNumber = new.start
        // Count by the header so content that looks like a diff header can't end the hunk early.
        while index < rows.count, oldLeft > 0 || newLeft > 0 {
            let row = rows[index]
            let text = string(row.dropFirst())
            switch row.first {
            case UInt8(ascii: "+"):
                lines.append(DiffLine(.addition, nil, newNumber, text)); newNumber += 1; newLeft -= 1
            case UInt8(ascii: "-"):
                lines.append(DiffLine(.deletion, oldNumber, nil, text)); oldNumber += 1; oldLeft -= 1
            case UInt8(ascii: "\\"):
                break
            default:
                lines.append(DiffLine(.context, oldNumber, newNumber, text))
                oldNumber += 1; newNumber += 1; oldLeft -= 1; newLeft -= 1
            }
            raw.append(row); index += 1
        }
        if index < rows.count, rows[index].first == UInt8(ascii: "\\") { raw.append(rows[index]); index += 1 }
        var joined = Data(raw.joined(separator: [0x0A])); joined.append(0x0A)
        return ParsedHunk(oldStart: old.start, newStart: new.start, context: context, lines: lines,
                          text: String(data: joined, encoding: .utf8))
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let pieces = text.split(separator: ",")
        guard let first = pieces.first, let start = Int(first) else { return nil }
        return (start, pieces.count > 1 ? Int(pieces[1]) ?? 1 : 1)
    }

    private static func string(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// `--- a/path`, `+++ b/path`, or `/dev/null`. Git appends a tab when the path has spaces.
    private static func path(fromMarker marker: String) -> String? {
        var value = marker
        if value.hasSuffix("\t") { value.removeLast() }
        value = unquote(value)
        if value == "/dev/null" { return nil }
        return value.hasPrefix("a/") || value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
    }

    /// Only used when there are no `---`/`+++` or rename lines, so both sides name the same path.
    private static func paths(fromGitLine line: String) -> String? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            guard let end = rest.dropFirst().range(of: "\" ")?.lowerBound else { return nil }
            return String(unquote(String(rest[rest.startIndex...end])).dropFirst(2))
        }
        let scalars = Array(rest.unicodeScalars)
        guard scalars.count >= 7, (scalars.count - 5) % 2 == 0 else { return nil }
        let length = (scalars.count - 5) / 2
        var view = String.UnicodeScalarView(); view.append(contentsOf: scalars[2..<(2 + length)])
        return String(view)
    }

    /// Undoes git's C-style quoting for paths with special characters.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        let bytes = Array(text.utf8.dropFirst().dropLast())
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count else { out.append(bytes[i]); i += 1; continue }
            let next = bytes[i + 1]
            if next >= 0x30, next <= 0x37, i + 3 < bytes.count,
               let value = UInt8(String(decoding: bytes[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                out.append(value); i += 4; continue
            }
            switch next {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            default: out.append(next)
            }
            i += 2
        }
        return String(decoding: out, as: UTF8.self)
    }
}
