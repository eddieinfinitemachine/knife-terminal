import Foundation

/// Finding a prompt you sent on the terminal, for the prompt rail. Claude Code echoes a prompt as a
/// row that starts with a lone marker ("> " or "❯ ") and then your words; the same words quoted in a
/// reply have text before them. Foundation only, so a plain swiftc script can compile it to test it.
enum RailSearch {
    /// Whitespace runs collapsed, trimmed, lowercased: how rows and prompts are compared.
    static func norm(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The opening of a prompt's first line, short enough to sit on one row of the terminal.
    static func snippet(_ prompt: String, cols: Int) -> String {
        String(norm(Pile.firstLine(prompt)).prefix(max(8, min(40, cols - 8))))
    }

    /// The `i`th prompt's snippet, and which match of it to take counting up from the bottom: the
    /// same opening may have been sent again since.
    static func target(_ prompts: [String], _ i: Int, cols: Int) -> (snippet: String, want: Int) {
        let s = snippet(prompts[i], cols: cols)
        return (s, prompts[i...].filter { norm(Pile.firstLine($0)).hasPrefix(s) }.count)
    }

    /// Whether a row shows the snippet, and whether as a prompt (after a marker of at most two
    /// symbols) rather than inside a reply.
    static func match(_ row: String, _ snippet: String) -> (found: Bool, asPrompt: Bool) {
        let r = norm(row)
        guard let at = r.range(of: snippet) else { return (false, false) }
        let before = r[..<at.lowerBound].trimmingCharacters(in: .whitespaces)
        return (true, !before.isEmpty && before.count <= 2 && !before.contains { $0.isLetter || $0.isNumber })
    }

    /// The row of the `want`th match from the bottom of the scrollback. Rows drawn as a prompt count
    /// first; when there aren't enough of those (an older Claude Code, a different marker) any row
    /// with the words will do. `skip` is the input row, where you may be typing them again.
    static func row(in rows: [String], snippet: String, want: Int, skip: Int? = nil) -> Int? {
        guard !snippet.isEmpty, want > 0 else { return nil }
        var prompts: [Int] = [], any: [Int] = []
        for y in rows.indices.reversed() where y != skip {
            let m = match(rows[y], snippet)
            if m.asPrompt { prompts.append(y) }
            if m.found { any.append(y) }
        }
        if prompts.count >= want { return prompts[want - 1] }
        return any.count >= want ? any[want - 1] : nil
    }

    /// On one screen (fullscreen Claude Code): a prompt row, else the first row with the words.
    static func screenRow(_ rows: [String], snippet: String, skip: Int? = nil) -> Int? {
        var fallback: Int?
        for y in rows.indices where y != skip {
            let m = match(rows[y], snippet)
            if m.asPrompt { return y }
            if m.found, fallback == nil { fallback = y }
        }
        return fallback
    }
}
