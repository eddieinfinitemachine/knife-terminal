import AppKit
import CoreServices

// ─── Unix socket server: Claude Code hooks + "open <dir>" pings ───

final class UnixSocketServer {
    private let path: String
    private var fd: Int32 = -1
    private var boundInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private let onMessage: (String) -> String?   // reply (written back before close), if any
    private let queue = DispatchQueue(label: "knife.socket")

    init(path: String, onMessage: @escaping (String) -> String?) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() {
        // Another live instance owns the path: leave its socket alone.
        // rebindIfNeeded() takes over if that instance later dies.
        guard !listenerAlive() else { return }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A client that has already gone (nc -w 1, a timed-out knife-tab) must not kill the app
        // when its reply is written. Set on the listener, which accepted sockets inherit: on the
        // accepted socket itself setsockopt fails with EINVAL once the peer has closed. Not
        // signal(SIGPIPE, SIG_IGN): the shells we fork would inherit an ignored SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = makeAddr()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); fd = -1; return }
        var st = stat()
        if stat(path, &st) == 0 { boundInode = st.st_ino }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
    }

    /// Recover when the socket file was deleted or replaced out from under us
    /// (e.g. a second app copy ran and quit): drop the orphaned fd and rebind.
    func rebindIfNeeded() {
        if fd < 0 { start(); return }
        var st = stat()
        if stat(path, &st) != 0 || st.st_ino != boundInode {
            acceptSource?.cancel(); acceptSource = nil
            close(fd); fd = -1; boundInode = 0
            start()
        }
    }

    private func listenerAlive() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var addr = makeAddr()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) }
        } == 0
    }

    private func makeAddr() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count - 1)))
            }
        }
        return addr
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // a "tab open" forks a shell while this connection is live — without CLOEXEC the
        // child inherits it and the client never sees EOF after the reply
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // a client that connects and says nothing is dropped instead of waited on forever
        var patience = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        // Read off the serial queue so a slow client holds up nobody else; messages are still
        // handled one at a time, in the order they finish arriving.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                if buf.count > 512 * 1024 { break }
            }
            guard let self else { close(client); return }
            self.queue.async {
                if let s = String(data: buf, encoding: .utf8), !s.isEmpty, let reply = self.onMessage(s) {
                    // client half-closed its write side (python shutdown(SHUT_WR)) and is waiting for this
                    _ = reply.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
                }
                close(client)
            }
        }
    }

    func stop() {
        acceptSource?.cancel(); acceptSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        // Only delete the file if it's still ours — never a newer instance's socket.
        var st = stat()
        if boundInode != 0, stat(path, &st) == 0, st.st_ino == boundInode { unlink(path) }
        boundInode = 0
    }
}

// ─── Claude Code alert hooks: install into the account's settings.json (~/.claude, or Knife 2's config dir) ───

enum HooksInstaller {
    /// KNIFE_SOCK (set by the app that opened the tab) picks which Knife hears the hook, so one account's
    /// settings serve both apps; without it (a tab from an older Knife) it's the main app's socket.
    static let hookCmd = "[ -n \"$KNIFE_TAB\" ] && { printf '%s ' \"$KNIFE_TAB\"; cat; } | nc -U -w 1 \"${KNIFE_SOCK:-$HOME/.knife-terminal.sock}\" >/dev/null 2>&1; exit 0"
    /// What installs before KNIFE_SOCK wrote; `upgrade()` rewrites it to `hookCmd`.
    static let legacyHookCmd = "[ -n \"$KNIFE_TAB\" ] && { printf '%s ' \"$KNIFE_TAB\"; cat; } | nc -U -w 1 \"$HOME/.knife-terminal.sock\" >/dev/null 2>&1; exit 0"
    static let events = ["Stop", "Notification", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "TaskCompleted", "SessionStart", "SessionEnd", "StopFailure"]
    // Codex CLI reads the same hook format from ~/.codex/hooks.json (no Notification/TaskCompleted events)
    static let codexEvents = ["Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "SessionEnd"]
    static var settingsPath: String { Instance.claudeDir + "/settings.json" }
    static var codexPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".codex/hooks.json") }

    static func installed() -> Bool {
        installed(at: settingsPath, events: events) && installed(at: codexPath, events: codexEvents)
    }

    private static func installed(at settingsPath: String, events: [String]) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = cfg["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            guard let arr = hooks[ev], let d = try? JSONSerialization.data(withJSONObject: arr),
                  let s = String(data: d, encoding: .utf8) else { return false }
            return s.contains("knife-terminal.sock")
        }
    }

    /// Hooks from an older Knife lack newer events (StopFailure) or KNIFE_SOCK routing: bring them up to date
    /// without asking — consent was given once.
    @MainActor
    static func upgrade() {
        guard let s = try? String(contentsOfFile: settingsPath, encoding: .utf8), s.contains("knife-terminal.sock") else { return }
        if !installed(at: settingsPath, events: events) || hasLegacy(at: settingsPath) {
            _ = write(to: settingsPath, events: events, quiet: true) // at launch: a file we can't parse is skipped silently
        }
    }

    private static func hasLegacy(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = cfg["hooks"] as? [String: Any] else { return false }
        return migrated(hooks).changed
    }

    /// `hooks` with every legacy Knife command swapped for `hookCmd`; nothing else is touched.
    static func migrated(_ hooks: [String: Any]) -> (hooks: [String: Any], changed: Bool) {
        var changed = false, out = hooks
        for (ev, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            out[ev] = groups.map { group -> [String: Any] in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                var g = group
                g["hooks"] = list.map { h -> [String: Any] in
                    guard h["command"] as? String == legacyHookCmd else { return h }
                    changed = true
                    var h = h; h["command"] = hookCmd; return h
                }
                return g
            }
        }
        return (out, changed)
    }

    @MainActor
    static func install() -> Bool {
        if installed() { return true }
        let alert = NSAlert()
        alert.messageText = "Add Claude Code + Codex hooks for attention alerts?"
        alert.informativeText = "Adds hooks (\(events.joined(separator: ", "))) to \(settingsPath) and \(codexPath). Each hook pings the Knife that opened the tab (via its socket, ~/.knife-terminal.sock for the main app) so the tab shows a thinking animation while the agent works and glows with a chime when it's waiting for you. Nothing else in the files is changed."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return write(to: settingsPath, events: events) && write(to: codexPath, events: codexEvents)
    }

    /// The settings file's contents with our hooks added, or nil when the file holds
    /// something we can't read as the JSON we expect. Nil means don't write: starting
    /// over from an empty config would replace the user's whole settings file
    /// (permissions, env, other hooks) with just our hooks.
    static func merged(_ existing: Data?, events: [String], hookCmd: String) -> [String: Any]? {
        var cfg: [String: Any] = [:]
        if let existing, !(String(data: existing, encoding: .utf8) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let j = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            cfg = j
        }
        if cfg["hooks"] != nil, !(cfg["hooks"] is [String: Any]) { return nil }
        var hooks = migrated(cfg["hooks"] as? [String: Any] ?? [:]).hooks
        for ev in events {
            if hooks[ev] != nil, !(hooks[ev] is [Any]) { return nil }
            var arr = hooks[ev] as? [Any] ?? []
            let d = (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !d.contains("knife-terminal.sock") {
                arr.append(["matcher": "", "hooks": [["type": "command", "command": hookCmd]]])
            }
            hooks[ev] = arr
        }
        cfg["hooks"] = hooks
        return cfg
    }

    @MainActor
    private static func write(to settingsPath: String, events: [String], quiet: Bool = false) -> Bool {
        guard let cfg = merged(FileManager.default.contents(atPath: settingsPath), events: events, hookCmd: hookCmd) else {
            if !quiet {
                let err = NSAlert(); err.messageText = "Hooks not installed"
                err.informativeText = "\(settingsPath) is not valid JSON (or its hooks are not in the usual shape), so Knife left it alone. Fix the file and try again."
                err.runModal()
            }
            return false
        }
        do {
            try FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (String(data: out, encoding: .utf8)! + "\n").write(toFile: settingsPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            let err = NSAlert(); err.messageText = "Could not write settings"; err.informativeText = String(describing: error)
            err.runModal()
            return false
        }
    }
}

// ─── Default terminal registration (was build/set-default.swift) ───

enum DefaultTerminal {
    static let utis = ["com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable", "public.bash-script", "public.zsh-script"]
    static let schemes = ["ssh", "telnet", "x-man-page"]

    @MainActor
    static func register() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.cwandt.knifeterminal"
        var failures = 0
        var detail = ""
        for u in utis {
            let r = LSSetDefaultRoleHandlerForContentType(u as CFString, .all, bundleId as CFString)
            detail += "\(r == 0 ? "ok " : "ERR") uti    \(u)\n"; if r != 0 { failures += 1 }
        }
        for s in schemes {
            let r = LSSetDefaultHandlerForURLScheme(s as CFString, bundleId as CFString)
            detail += "\(r == 0 ? "ok " : "ERR") scheme \(s)\n"; if r != 0 { failures += 1 }
        }
        let alert = NSAlert()
        alert.messageText = failures == 0 ? "Knife Terminal is now the default terminal." : "Some handlers could not be set."
        alert.informativeText = detail + "\nKnife now opens .command/.sh/.tool files, unix executables, and ssh:// / telnet:// links. Folders: right-click → Open With → Knife Terminal."
        alert.runModal()
    }
}

// ─── Recent Claude Code projects (from ~/.claude.json) ───

struct Project: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let t: TimeInterval
}

enum ProjectSection: String, Codable, CaseIterable {
    /// Flagged for review: above ★, and ahead of it — a flagged star shows here. Never an
    /// override and never a folder's section; a project is here only while `flagged` is set.
    case review
    case starred, active, dormant, archived
}

struct ProjectMeta: Codable, Equatable {
    var starred = false
    var override: ProjectSection? = nil
    var name: String? = nil   // custom display name; folder on disk is untouched
    /// When it was flagged for review; nil = not flagged. Its folder, star and place in its own
    /// section are left as they are, so clearing the flag puts it back where it was.
    var flagged: Date? = nil
}

enum Projects {
    /// Optional fields came later: a file saved before them still decodes.
    struct SidebarMeta: Codable {
        var byPath: [String: ProjectMeta] = [:]
        var order: [String: [String]] = [:]
        var tree: FolderTree? = nil   // folders made in the sidebar (SidebarFolders.swift)
        var roots: [String]? = nil    // folders added from disk, scanned like codeRoots

        /// "flag for review" / "done reviewing": only the flag changes, so the project comes back
        /// to its folder, its star and its spot in its section.
        mutating func setFlag(_ path: String, _ on: Bool, now: Date = Date()) {
            var saved = byPath[path] ?? ProjectMeta()
            saved.flagged = on ? (saved.flagged ?? now) : nil
            byPath[path] = saved
        }

        /// A project let go in `target` (a drag, or "move to …"). Into review it's flagged and
        /// nothing else changes. Anywhere else it's unflagged and takes that section, filed in
        /// `folder` (nil = loose); `snapshot` is the section's order as drawn, if the drop has one.
        mutating func drop(_ p: Project, into target: ProjectSection, folder: String?, order snapshot: [String]?) {
            guard target != .review else { return setFlag(p.path, true) }
            var saved = byPath[p.path] ?? ProjectMeta()
            saved.flagged = nil
            if target == .starred {
                saved.starred = true
            } else {
                saved.starred = false
                saved.override = target == Projects.autoSection(p) ? nil : target
            }
            byPath[p.path] = saved
            var t = tree ?? FolderTree()
            t.file(p.path, into: folder)
            tree = t
            for section in ProjectSection.allCases {
                let key = section.rawValue
                order[key]?.removeAll { $0 == p.path }
                if order[key]?.isEmpty == true { order.removeValue(forKey: key) }
            }
            if let snapshot { order[target.rawValue] = snapshot }
        }
    }

    static func encode(_ p: String) -> String {
        String(p.map { c in c.isLetter || c.isNumber ? c : "-" })
    }

    private static let touchKey = "knife.projectOpened"
    private static let metaKey = "knife.projectMeta"

    static func loadMeta() -> SidebarMeta {
        guard let data = UserDefaults.standard.data(forKey: metaKey),
              let meta = try? JSONDecoder().decode(SidebarMeta.self, from: data) else {
            return SidebarMeta()
        }
        return meta
    }

    static func saveMeta(_ meta: SidebarMeta) {
        let cleaned = cleaned(meta, projects: list(extraRoots: meta.roots ?? []))
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        UserDefaults.standard.set(data, forKey: metaKey)
    }

    /// What saveMeta keeps: entries for listed projects only, and each section's order holding
    /// just the projects whose home it is. A flagged project keeps its spot in its home section's
    /// order (review has none: it's by flag time), so clearing the flag puts it back there.
    static func cleaned(_ meta: SidebarMeta, projects: [Project]) -> SidebarMeta {
        var cleaned = meta
        let currentPaths = Set(projects.map(\.path))
        cleaned.byPath = cleaned.byPath.filter {
            currentPaths.contains($0.key) && $0.value != ProjectMeta()
        }
        cleaned.tree?.prune(keeping: currentPaths)
        if cleaned.tree?.isEmpty == true { cleaned.tree = nil }
        if cleaned.roots?.isEmpty == true { cleaned.roots = nil }
        let home = Dictionary(projects.map { ($0.path, section(of: $0, meta: cleaned, flag: false)) },
                              uniquingKeysWith: { a, _ in a })
        var order: [String: [String]] = [:]
        for section in ProjectSection.allCases where section != .review {
            let key = section.rawValue
            let live = (cleaned.order[key] ?? []).filter { home[$0] == section }
            if !live.isEmpty { order[key] = live }
        }
        cleaned.order = order
        return cleaned
    }

    /// Remember that a project was just opened from Knife, so it sorts to the
    /// top immediately (transcript mtimes only catch up once Claude writes).
    static func touch(_ path: String) {
        var d = UserDefaults.standard.dictionary(forKey: touchKey) as? [String: Double] ?? [:]
        d[path] = Date().timeIntervalSince1970
        if d.count > 60 {
            d = Dictionary(uniqueKeysWithValues: Array(d.sorted { $0.value > $1.value }.prefix(40)))
        }
        UserDefaults.standard.set(d, forKey: touchKey)
    }

    /// Directories scanned for projects in addition to whatever Claude Code
    /// has in ~/.claude.json (which only knows dirs `claude` was run in, and
    /// loses recency once transcripts age out of ~/.claude/projects).
    static let codeRoots = ["Code/active", "Code/tools", "Code/experiments", "Code/archive"]

    static var builtInRoots: [String] { codeRoots.map { (NSHomeDirectory() as NSString).appendingPathComponent($0) } }

    /// The form a root is kept and compared in, so ~/x, /Users/me/x/ and a symlink to it are one root.
    static func canonRoot(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func autoSection(_ p: Project, now: TimeInterval = Date().timeIntervalSince1970) -> ProjectSection {
        let archive = NSHomeDirectory() + "/Code/archive/"
        if p.path.hasPrefix(archive) { return .archived }
        return p.t >= now - 24 * 60 * 60 ? .active : .dormant  // worked on in the last day
    }

    /// The section a project shows in. `flag: false` gives its home — where it is when not
    /// flagged, and where clearing the flag returns it.
    static func section(of p: Project, meta: SidebarMeta, flag: Bool = true) -> ProjectSection {
        let saved = meta.byPath[p.path] ?? ProjectMeta()
        if flag && saved.flagged != nil { return .review }
        if saved.starred { return .starred }
        if let o = saved.override, o != .review { return o }
        return autoSection(p)
    }

    /// Review's order: newest flagged first. One not flagged yet (being dragged in) counts as
    /// flagged `now`, so it sits on top, where the drop will put it.
    static func reviewOrder(_ projects: [Project], meta: SidebarMeta, now: Date = Date()) -> [Project] {
        func at(_ p: Project) -> Date { meta.byPath[p.path]?.flagged ?? now }
        return projects.sorted { at($0) != at($1) ? at($0) > at($1) : $0.t > $1.t }
    }

    static func sectioned(_ projects: [Project], meta: SidebarMeta) -> [(ProjectSection, [Project])] {
        var grouped = Dictionary(uniqueKeysWithValues: ProjectSection.allCases.map { ($0, [Project]()) })
        for p in projects {
            grouped[section(of: p, meta: meta), default: []].append(p)
        }
        return ProjectSection.allCases.map { section in
            let members = grouped[section, default: []]
            if section == .review { return (section, reviewOrder(members, meta: meta)) }
            let byPath = Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0) })
            var seen = Set<String>()
            let ordered = (meta.order[section.rawValue] ?? []).compactMap { path -> Project? in
                guard seen.insert(path).inserted else { return nil }
                return byPath[path]
            }
            let remaining = members.filter { !seen.contains($0.path) }.sorted { $0.t > $1.t }
            return (section, ordered + remaining)
        }
    }

    /// `extraRoots`: folders added from disk; by default the saved ones.
    static func list(extraRoots: [String]? = nil) -> [Project] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let projDir = Instance.claudeDir + "/projects"
        let touched = UserDefaults.standard.dictionary(forKey: touchKey) as? [String: Double] ?? [:]

        var paths = Set<String>()
        if let data = fm.contents(atPath: Instance.claudeJSON),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = cfg["projects"] as? [String: Any] {
            paths.formUnion(projects.keys)
        }
        for base in builtInRoots + (extraRoots ?? loadMeta().roots ?? []) {
            for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !name.hasPrefix(".") {
                paths.insert((base as NSString).appendingPathComponent(name))
            }
        }

        return paths
            .filter { !$0.contains("/.claude-worktrees/") && !$0.contains("/.knife/") && fm.fileExists(atPath: $0) }
            .compactMap { p -> Project? in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
                let enc = (projDir as NSString).appendingPathComponent(encode(p))
                // most recently used from Knife (opened or switched to); a project never
                // touched here falls back to its newest transcript (appends bump file
                // mtime, not the dir's), so a busy background session can't outrank
                // the one you just used
                var t: TimeInterval = 0
                if let k = touched[p] { t = k } else {
                    for f in (try? fm.contentsOfDirectory(atPath: enc)) ?? [] {
                        if let a = try? fm.attributesOfItem(atPath: (enc as NSString).appendingPathComponent(f)),
                           let m = a[.modificationDate] as? Date {
                            t = max(t, m.timeIntervalSince1970)
                        }
                    }
                }
                // a folder with no Claude history (one added from disk): its own mtime
                if t == 0, let a = try? fm.attributesOfItem(atPath: p),
                   let m = a[.modificationDate] as? Date {
                    t = m.timeIntervalSince1970
                }
                return Project(path: p, name: (p as NSString).lastPathComponent, t: t)
            }
            .sorted { $0.t > $1.t }
    }
}

// ─── Context files: md files Claude Code loads globally / per project ───

struct ContextFile: Identifiable {
    var id: String { path }
    let path: String
    let size: Int
}

enum ContextFiles {
    private static func stat(_ p: String) -> ContextFile? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? Int else { return nil }
        return ContextFile(path: p, size: size)
    }

    static func global() -> [ContextFile] {
        return ["/Library/Application Support/ClaudeCode/CLAUDE.md",
                Instance.claudeDir + "/CLAUDE.md",
                Instance.claudeDir + "/CLAUDE.local.md"].compactMap(stat)
    }

    static func session(cwd: String?) -> (cwd: String?, files: [ContextFile]) {
        guard let cwd else { return (nil, []) }
        var files: [ContextFile] = []
        var dir = cwd
        for _ in 0..<40 {
            for n in ["CLAUDE.md", "CLAUDE.local.md"] {
                if let f = stat((dir as NSString).appendingPathComponent(n)) { files.append(f) }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        let mem = Instance.claudeDir + "/projects/\(Projects.encode(cwd))/memory/MEMORY.md"
        if let f = stat(mem) { files.append(f) }
        return (cwd, files)
    }
}
