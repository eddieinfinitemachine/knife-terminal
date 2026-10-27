import Foundation

/// Where Claude Code keeps a folder's sessions: ~/.claude/projects/<cwd with every non-alphanumeric
/// turned into "-">/<session id>.jsonl. One slug for the chat view and the project menu.
enum ClaudeProjects {
    static func dir(for cwd: String) -> String {
        NSHomeDirectory() + "/.claude/projects/" + String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

struct RecentChat: Identifiable, Equatable {
    let id: String       // the session id: `claude --resume <id>`
    let title: String
    let modified: Date
}

/// A project's saved Claude Code chats, newest first, each with what to call it: the name you
/// gave it (/rename), else the title Claude wrote, else the first thing you said. Titles are
/// re-appended as a chat goes on, so the tail of the file is read first and the head only when
/// the tail has none — never the whole of a multi-megabyte transcript.
enum RecentChats {
    static let tailBytes = 512 * 1024
    static let headBytes = 256 * 1024

    static func list(cwd: String, limit: Int = 15) -> [RecentChat] {
        let dir = ClaudeProjects.dir(for: cwd)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var files: [(id: String, path: String, mtime: Date, size: Int)] = []
        for name in names where name.hasSuffix(".jsonl") {
            let id = String(name.dropLast(6))
            guard id.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil,
                  let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name),
                  let m = attrs[.modificationDate] as? Date else { continue }
            files.append((id, dir + "/" + name, m, (attrs[.size] as? Int) ?? 0))
        }
        var out: [RecentChat] = []
        for f in files.sorted(by: { $0.mtime > $1.mtime }) {
            if let t = title(path: f.path, mtime: f.mtime, size: f.size) { out.append(RecentChat(id: f.id, title: t, modified: f.mtime)) }
            if out.count >= limit { break }
        }
        return out
    }

    /// "now", "12m", "3h", "2d".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let m = Int(now.timeIntervalSince(date) / 60)
        return m < 1 ? "now" : m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
    }

    // ─── Titles, cached by (path, mtime) ───

    private static var cache: [String: (mtime: Date, title: String?)] = [:]
    private static let lock = NSLock()

    private static func title(path: String, mtime: Date, size: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path], c.mtime == mtime { return c.title }
        let t = readTitle(path: path, size: size)
        if cache.count > 500 { cache.removeAll() } // ponytail: a crude cap; refilled on the next menu
        cache[path] = (mtime, t)
        return t
    }

    private static func readTitle(path: String, size: Int) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        func read(from offset: Int, count: Int) -> String {
            try? fh.seek(toOffset: UInt64(offset))
            return String(decoding: (try? fh.read(upToCount: count)) ?? Data(), as: UTF8.self)
        }
        var tail = read(from: max(0, size - tailBytes), count: min(size, tailBytes))
        guard size > tailBytes else { return title(tail: tail, head: nil) }
        if let nl = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) } // started mid-line
        return title(tail: tail, head: read(from: 0, count: headBytes))
    }

    /// Pure: the title from a file's tail (the whole file when it's short) and, for a long file,
    /// its head — custom title, else Claude's, else the first line of the first prompt (cut to 80).
    static func title(tail: String, head: String?) -> String? {
        if let t = titles(in: tail) ?? head.flatMap(titles(in:)) { return t }
        for line in (head ?? tail).split(separator: "\n") where line.contains("\"user\"") {
            guard let j = json(line), let text = promptText(j) else { continue }
            return String(Pile.firstLine(text).prefix(80))
        }
        return nil
    }

    /// The last `custom-title`, else the last `ai-title`.
    static func titles(in text: String) -> String? {
        var custom: String?, ai: String?
        for line in text.split(separator: "\n") where line.contains("-title\"") {
            guard let j = json(line) else { continue }
            if j["type"] as? String == "custom-title", let t = j["customTitle"] as? String, !t.isEmpty { custom = t }
            if j["type"] as? String == "ai-title", let t = j["aiTitle"] as? String, !t.isEmpty { ai = t }
        }
        return custom ?? ai
    }

    /// Something you typed, as opposed to plumbing: tool results, system reminders, interrupt
    /// notices, a slash command's output. A slash command reads as you typed it.
    static func promptText(_ j: [String: Any]) -> String? {
        guard j["type"] as? String == "user", j["isMeta"] as? Bool != true, j["isSidechain"] as? Bool != true else { return nil }
        let content = (j["message"] as? [String: Any])?["content"]
        var text = ""
        if let s = content as? String {
            text = s
        } else if let parts = content as? [[String: Any]], !parts.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let cmd = tag("command-name", in: text) {
            let args = tag("command-args", in: text) ?? ""
            return (cmd + (args.isEmpty ? "" : " " + args)).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.range(of: #"^(<[a-z-]+>|\[Request interrupted|Caveat:)"#,
                                            options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return trimmed
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}
