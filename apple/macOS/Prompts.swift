import Foundation
import Combine

// The sidebar's saved prompts and clipboard pile, and the repo identity prompts are kept to.
// Foundation only, so a plain swiftc script can compile this file to test it.

// ─── Saved prompts: ~/.knife/prompts.json, one list every window shows ───

struct SavedPrompt: Codable, Identifiable {
    var id = UUID()          // this run only; the file has no ids
    var name: String?
    var text: String
    var repo: String?        // RepoKey.key — listed only while the active tab is in that repo
    var repoName: String?

    private enum CodingKeys: String, CodingKey { case name, text, repo, repoName }

    /// From one entry of the file, which may have been edited by hand: `text` is all it needs.
    init?(json: [String: Any]) {
        guard let text = json["text"] as? String else { return nil }
        self.text = text
        name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        repo = json["repo"] as? String
        repoName = json["repoName"] as? String
    }

    init(name: String?, text: String, repo: String? = nil, repoName: String? = nil) {
        self.name = name; self.text = text; self.repo = repo; self.repoName = repoName
    }

    var label: String { name ?? Pile.firstLine(text) }
}

/// What a sidebar row shows for a block of text: its first non-empty line, trimmed.
enum Pile {
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Newest first, a repeat moves to the top, at most `cap`; whitespace-only text is ignored.
    static func inserting(_ text: String, into list: [String], cap: Int = 20) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return list }
        return Array(([text] + list.filter { $0 != text }).prefix(cap))
    }
}

@MainActor
final class PromptStore: ObservableObject {
    @Published private(set) var all: [SavedPrompt] = []
    private let url: URL
    private var onDisk: Data?   // the file as last read or written: an unchanged file isn't re-parsed

    init(path: String) {
        url = URL(fileURLWithPath: path)
        reload()
    }

    /// Re-read the file (on app activation, since it may have been edited by hand).
    func reload() {
        let data = try? Data(contentsOf: url)
        guard data != onDisk else { return }
        onDisk = data
        let raw = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any] ?? []
        all = raw.compactMap { ($0 as? [String: Any]).flatMap(SavedPrompt.init(json:)) }
    }

    func add(_ p: SavedPrompt) { all.append(p); save() }

    func update(_ id: UUID, _ change: (inout SavedPrompt) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        save()
    }

    func delete(_ id: UUID) { all.removeAll { $0.id == id }; save() }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        onDisk = data
    }
}

// ─── Clipboard pile: what Knife copied (terminal ⌘C, OSC 52), ~/.knife/clips.json ───

@MainActor
final class ClipPile: ObservableObject {
    @Published private(set) var clips: [String] = []
    private let url: URL

    init(path: String) {
        url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) {
            clips = list
        }
    }

    func add(_ text: String) { set(Pile.inserting(text, into: clips)) }
    func remove(_ text: String) { set(clips.filter { $0 != text }) }
    func clear() { set([]) }

    private func set(_ next: [String]) {
        guard next != clips else { return }
        clips = next
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(clips).write(to: url, options: .atomic)
    }
}

// ─── Repo identity: one key for every clone and worktree of a repo ───

struct RepoKey: Equatable {
    let key: String    // normalized origin remote ("github.com/o/r"), else the checkout's root path
    let name: String   // "r"
}

enum Repos {
    /// The repo `path` is in, by walking up to the nearest `.git`. Manifest.remote(of:) isn't
    /// reused: it only looks at `path` itself, skips worktrees, and runs git through a login shell.
    static func key(for path: String) -> RepoKey? {
        guard let (root, config) = locate(path) else { return nil }
        if let url = originURL(inConfig: cachedConfig(config)), let key = normalize(remote: url) {
            return RepoKey(key: key, name: (key as NSString).lastPathComponent)
        }
        return RepoKey(key: root, name: (root as NSString).lastPathComponent)
    }

    /// The checkout's root and the config file holding its remotes. A worktree's `.git` is a file
    /// ("gitdir: …") pointing at its own folder, whose `commondir` points at the shared one.
    static func locate(_ path: String) -> (root: String, config: String)? {
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        for _ in 0..<40 {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue { return (dir, dotGit + "/config") }
                guard let file = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      let line = file.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                var gitdir = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: dir)
                if let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) {
                    gitdir = resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), against: gitdir)
                }
                return (dir, gitdir + "/config")
            }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir || up.isEmpty { return nil }
            dir = up
        }
        return nil
    }

    private static func resolve(_ p: String, against base: String) -> String {
        ((p.hasPrefix("/") ? p : base + "/" + p) as NSString).standardizingPath
    }

    /// `[remote "origin"]`'s url, else the first remote's.
    static func originURL(inConfig text: String) -> String? {
        var section = ""
        var urls: [(remote: String, url: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section.hasPrefix("[remote "), line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            urls.append((section, parts[1].trimmingCharacters(in: .whitespaces)))
        }
        return (urls.first { $0.remote == "[remote \"origin\"]" } ?? urls.first)?.url
    }

    /// git@github.com:o/r.git, ssh://git@github.com:22/o/r and https://github.com/o/r/ → github.com/o/r.
    static func normalize(remote: String) -> String? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = r.range(of: "^[a-z][a-z0-9+.-]*://", options: .regularExpression) { r.removeSubrange(scheme) }
        if let user = r.range(of: "^[^@/]+@", options: .regularExpression) { r.removeSubrange(user) }
        if let port = r.range(of: "^[^/:]+:[0-9]+/", options: .regularExpression) { // host:22/path → host/path
            let host = r[port].prefix { $0 != ":" }
            r.replaceSubrange(port, with: host + "/")
        } else if let colon = r.range(of: "^[^/:]+:", options: .regularExpression) { // scp-style host:path
            r.replaceSubrange(colon, with: r[colon].dropLast() + "/")
        }
        while r.hasSuffix("/") { r.removeLast() }
        if r.hasSuffix(".git") { r.removeLast(4) }
        while r.hasSuffix("/") { r.removeLast() }
        return r.isEmpty ? nil : r
    }

    // The sidebar asks on every tab switch; the config only changes when a remote does.
    private static var configCache: [String: (mtime: Date, text: String)] = [:]
    private static let lock = NSLock()

    private static func cachedConfig(_ path: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "" }
        if let c = configCache[path], c.mtime == m { return c.text }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        configCache[path] = (m, text)
        return text
    }
}
