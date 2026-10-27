import Foundation

// Folder trust. Claude Code asks "do you trust this folder?" the first time it runs somewhere. For a
// repo cloned from a stranger that question is the point; for your own projects it's a keystroke in
// the way of every new tab. So Knife answers it ahead of time for folders that are yours, by setting
// projects[<folder>].hasTrustDialogAccepted in ~/.claude.json, and leaves anyone else's checkout to ask.
//
// "Yours": a repo whose remote's owner is in ~/.knife/config.json's trustedOwners, a repo with no
// remote, or an ordinary folder outside any repo. `"autoTrust": false` there turns it all off.
// Foundation only, so a plain swiftc script can compile this file (with Prompts.swift) to test it.

struct TrustConfig: Equatable {
    var autoTrust = true
    var trustedOwners: [String] = []   // lowercased
}

enum FolderTrust {
    /// Where a folder's code came from.
    enum Checkout: Equatable {
        case none                       // not in a repo
        case local                      // a repo with no remote (or one on this disk): you made it
        case remote(owner: String?)     // "github.com/<owner>/…"; nil when the remote names no account
    }

    // ─── Pure ───

    /// "github.com/owner/repo" (Repos.normalize) → "owner". GitLab subgroups keep the top group.
    static func owner(ofRemote key: String) -> String? {
        let parts = key.split(separator: "/")
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    static func checkout(remoteURL: String?) -> Checkout {
        guard let url = remoteURL?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return .local }
        if url.hasPrefix("/") || url.hasPrefix("~") || url.hasPrefix(".") || url.hasPrefix("file:") { return .local }
        guard let key = Repos.normalize(remote: url) else { return .local }
        return .remote(owner: owner(ofRemote: key))
    }

    static func isYours(_ c: Checkout, config: TrustConfig) -> Bool {
        guard config.autoTrust else { return false }
        switch c {
        case .none, .local: return true
        case .remote(let owner?): return config.trustedOwners.contains(owner.lowercased())
        case .remote(nil): return false // a remote with no account in it: can't say it's yours
        }
    }

    /// ~/.knife/config.json as read (nil: no file) → the config to use, and what to write back when it
    /// lacks trustedOwners (seeded, every other key kept). A file that doesn't parse is yours to fix:
    /// it turns trust off and is never overwritten.
    static func config(from data: Data?, seedOwners: () -> [String]) -> (config: TrustConfig, write: Data?) {
        var root: [String: Any] = [:]
        if let data {
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return (TrustConfig(autoTrust: false), nil)
            }
            root = j
        }
        var write: Data?
        if root["trustedOwners"] == nil, root["autoTrust"] as? Bool != false {
            if root["autoTrust"] == nil { root["autoTrust"] = true }
            root["trustedOwners"] = seedOwners()
            write = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        let owners = (root["trustedOwners"] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() }
        return (TrustConfig(autoTrust: root["autoTrust"] as? Bool ?? true, trustedOwners: owners), write)
    }

    /// What Claude Code writes for a folder it hasn't seen (its own defaults, as of 2.1.312): an entry
    /// with only the flag could trip code that expects the rest.
    static let newProject: [String: Any] = [
        "allowedTools": [String](), "mcpContextUris": [String](), "mcpServers": [String: Any](),
        "enabledMcpjsonServers": [String](), "disabledMcpjsonServers": [String](),
        "hasTrustDialogAccepted": false,
        "hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false,
    ]

    enum Edit: Equatable {
        case unchanged
        case updated(Data)
        case unreadable   // not the JSON we expect: never written
    }

    /// Which key to mark, and which keys above it already cover it. Claude Code's check (2.1.312)
    /// walks up from its cwd and takes the first trusted key, stopping at the checkout's root. So a
    /// checkout is marked at its root, which covers every folder in it, and an ordinary folder is
    /// already trusted when a folder above it is: nothing is written for it. That matters beyond
    /// tidiness: the sidebar lists ~/.claude.json's keys as projects.
    static func scope(of key: String, checkoutRoot: String?) -> (mark: String, coveredBy: [String]) {
        if let checkoutRoot { return (checkoutRoot, []) }
        var above: [String] = [], dir = key
        while dir != "/" && !dir.isEmpty {
            dir = (dir as NSString).deletingLastPathComponent
            above.append(dir)
        }
        return (key, above)
    }

    /// ~/.claude.json with `key` marked trusted, and any existing key that `sameFolder` says is the
    /// same folder spelled another way (a symlink): Claude keys on the spelling it was launched with.
    /// Unchanged when a `coveredBy` key is trusted already. Every other key is kept as it was.
    static func trusting(_ key: String, in data: Data, coveredBy: [String] = [],
                         sameFolder: (String) -> Bool = { _ in false }) -> Edit {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        var projects: [String: Any] = [:]
        if let p = root["projects"] {
            guard let d = p as? [String: Any] else { return .unreadable }
            projects = d
        }
        if coveredBy.contains(where: { (projects[$0] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true }) { return .unchanged }
        var changed = false
        for k in Set(projects.keys.filter(sameFolder) + [key]) {
            var entry = newProject
            if let e = projects[k] {
                guard let d = e as? [String: Any] else { return .unreadable }
                entry = d
            }
            if entry["hasTrustDialogAccepted"] as? Bool == true { continue }
            entry["hasTrustDialogAccepted"] = true
            projects[k] = entry
            changed = true
        }
        guard changed else { return .unchanged }
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return .unreadable }
        return .updated(out)
    }

    // ─── The disk ───

    /// The key Claude Code files a folder under: its cwd as the kernel reports it (getcwd, so
    /// symlinks resolved: ~/Dropbox/x is filed as ~/Dropbox (Personal)/x), NFC-normalized.
    static func configKey(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath.precomposedStringWithCanonicalMapping }
        defer { free(r) }
        return String(cString: r).precomposedStringWithCanonicalMapping
    }

    /// The repo a folder is in, by walking up to its `.git` (worktrees included): its remote and root.
    static func checkout(at dir: String) -> (checkout: Checkout, root: String?) {
        guard let (root, config) = Repos.locate(dir) else { return (.none, nil) }
        // root as Claude keys it: Repos standardizes paths, which drops /private from /private/var
        return (checkout(remoteURL: Repos.originURL(inConfig: (try? String(contentsOfFile: config, encoding: .utf8)) ?? "")), configKey(root))
    }

    /// The accounts you work under, from the remotes of checkouts you already have: the seed.
    static func owners(ofCheckouts paths: [String]) -> [String] {
        var owners = Set<String>()
        for p in paths { if case .remote(let o?) = checkout(at: p).checkout { owners.insert(o) } }
        return owners.sorted()
    }
}

/// Settles folders on one serial queue, each once per run, so cd'ing around costs a set lookup.
final class TrustKeeper: @unchecked Sendable {
    let claudeJSON: String
    let configPath: String
    private let knownCheckouts: () -> [String]
    private let queue = DispatchQueue(label: "knife.folder-trust", qos: .utility)
    private var seen: Set<String> = []      // queue only: paths as given
    private var decided: Set<String> = []   // queue only: config keys

    init(claudeJSON: String, configPath: String, knownCheckouts: @escaping () -> [String]) {
        self.claudeJSON = claudeJSON
        self.configPath = configPath
        self.knownCheckouts = knownCheckouts
    }

    /// Does this command start Claude Code? (`claude`, `claude -c`, `… && claude`)
    static func runsClaude(_ cmd: String) -> Bool {
        cmd.range(of: #"(^|[\s;&|(/])claude(?=$|[\s;&|)])"#, options: .regularExpression) != nil
    }

    func settle(_ dir: String) { queue.async { self.settleNow(dir) } }

    /// Decide `dir` and mark it trusted when it's yours. True when ~/.claude.json was written.
    @discardableResult
    func settleNow(_ dir: String) -> Bool {
        guard seen.insert(dir).inserted else { return false }
        let key = FolderTrust.configKey(dir)
        guard decided.insert(key).inserted else { return false }
        let (cfg, seed) = FolderTrust.config(from: FileManager.default.contents(atPath: configPath),
                                             seedOwners: { FolderTrust.owners(ofCheckouts: knownCheckouts()) })
        if let seed {
            try? FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = Self.replace(configPath, with: seed)
        }
        let (checkout, root) = FolderTrust.checkout(at: key)
        guard FolderTrust.isYours(checkout, config: cfg) else { return false }
        let (mark, covered) = FolderTrust.scope(of: key, checkoutRoot: root)
        let same: (String) -> Bool = { FolderTrust.configKey($0) == mark }
        // A look without the lock first: most folders are already trusted, and then nothing is locked or written.
        guard let before = FileManager.default.contents(atPath: claudeJSON),
              case .updated = FolderTrust.trusting(mark, in: before, coveredBy: covered, sameFolder: same) else { return false }
        let wrote = withClaudeLock { () -> Bool in
            // re-read under the lock, right before writing: Claude Code rewrites this file all the time
            guard let data = FileManager.default.contents(atPath: claudeJSON),
                  case .updated(let out) = FolderTrust.trusting(mark, in: data, coveredBy: covered, sameFolder: same) else { return false }
            return Self.replace(claudeJSON, with: out)
        }
        if wrote == nil { seen.remove(dir); decided.remove(key) } // Claude held the lock throughout: try again next time
        return wrote ?? false
    }

    /// Claude Code takes `~/.claude.json.lock` (a directory: proper-lockfile) around its own writes.
    /// Take the same lock so neither side's read-modify-write lands on the other's; nil when it
    /// stayed busy for half a second. A lock older than proper-lockfile's 10 s stale mark is a
    /// crashed process's, and ours is gone within milliseconds, so neither blocks for long.
    private func withClaudeLock<T>(_ body: () -> T) -> T? {
        let lock = claudeJSON + ".lock"
        for attempt in 0..<10 {
            if mkdir(lock, 0o755) == 0 {
                defer { rmdir(lock) }
                return body()
            }
            guard errno == EEXIST else { return body() } // can't lock here at all (read-only dir?): the rename is still atomic
            if attempt == 9, let m = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
               m.timeIntervalSinceNow < -10 { return body() }
            usleep(50_000)
        }
        return nil
    }

    /// Atomic replace: a temp file beside it (same volume), then rename. Keeps the file's permissions
    /// (~/.claude.json is 0600: it holds account details) and follows a symlinked file to its target.
    static func replace(_ path: String, with data: Data) -> Bool {
        let target = FileManager.default.fileExists(atPath: path) ? FolderTrust.configKey(path) : path
        let mode = ((try? FileManager.default.attributesOfItem(atPath: target))?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let tmp = target + ".knife-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp"
        // created 0600 and only then given the file's mode: never readable by others mid-write
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        var ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        ok = ok && fchmod(fd, mode_t(mode)) == 0 && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, target) == 0 else { unlink(tmp); return false }
        return true
    }
}
