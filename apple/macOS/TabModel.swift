import AppKit
import SwiftTerm
import KnifeKit

struct TabOptions {
    var cwd: String?
    var cmd: String?
    var title: String?       // fixed title (project name, "man ls", …) — OSC titles don't override it
    var shownTitle: String?   // restored display title
    var context: String?      // restored context line (see TabModel.context)
    var contextPinned = false
    var restoreCmd: String?
    var lastActivity: Date?   // restored from the session file, or now for a tab opened to work in
}

enum TabStatus {
    case idle, working, ready, needsInput
}

@MainActor
final class TabModel: NSObject, ObservableObject, Identifiable {
    let id: Int
    let view: KnifeTermView
    let emoji: String
    let opts: TabOptions
    @Published var title: String
    /// What the session is on, shown after the name as "name | context". For a tab whose
    /// name is fixed (a project tab, or a renamed one) it's Claude Code's terminal title —
    /// its own running summary of the conversation — unless the user wrote one in rename.
    @Published var context: String?
    var renamed = false          // the user named a plain shell: its terminal titles now feed `context`
    var contextPinned = false    // the user wrote the context: terminal titles no longer replace it
    var titleIsFixed: Bool { opts.title != nil || renamed }
    var displayTitle: String { context.map { "\(title) | \($0)" } ?? title }
    @Published var working = false
    @Published var attention = false
    @Published var status: TabStatus = .idle
    /// Last hook event, keystroke, or open; orders the sidebar's groups. Deliberately not
    /// @Published: it moves on every keystroke, which mustn't redraw the sidebar.
    var lastActivity: Date?
    /// The sidebar group: the repo (or folder) the shell is in. Worked out when the cwd changes —
    /// at open, on an OSC 7, and on the app's 15 s timer — never per render.
    @Published private(set) var repoGroup = TabGroupID.shell
    private var repoGroupCwd: String??   // the cwd repoGroup was worked out for; nil = not yet

    func refreshRepoGroup() {
        let cwd = currentCwd ?? opts.cwd
        guard repoGroupCwd != .some(cwd) else { return }
        repoGroupCwd = .some(cwd)
        let g = TabGroupID.of(cwd: cwd)
        if g != repoGroup { repoGroup = g }
    }

    /// Read on every regroup; the app's 15 s timer regroups, so a tab slides to dormant once its day is up.
    var groupMember: TabGroupMember {
        let urgency = TabUrgency.of(attention: attention, needsInput: status == .needsInput,
                                    working: working || status == .working)
        return TabGroupMember(id: id, group: repoGroup, urgency: urgency, lastActivity: lastActivity,
                              tier: .of(urgency: urgency, ready: status == .ready, lastActivity: lastActivity))
    }
    var limited = false        // the turn ended on a usage limit (StopFailure rate_limit)
    var sessionId: String?     // claude's session, from its hooks — restore resumes exactly this one
    var transcriptPath: String? // the agent's live transcript, from its hooks — the chat view reads exactly this one
    var lastReply: String?     // claude's last message at Stop, for the push
    var cols = 80
    var rows = 25
    var lastReportedCwd: String? // OSC 7, when the shell emits it
    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    /// Agent process alive under this tab's shell right now, if any.
    var runningAgent: String? {
        let pid = shellPid
        return pid > 0 ? Self.runningAgent(underShell: pid) : nil
    }

    var claudeRunning: Bool { runningAgent == "claude" }

    /// Which of these shells has an agent running under it, in one pass over the
    /// process table (under a millisecond). A pgrep per tab is a subprocess per
    /// tab — far too slow for a timer, and the answers wouldn't share an instant.
    ///
    /// Identification is by executable path, not process name: Claude Code renames
    /// itself to its version, so the kernel reports "2.1.270" and only the path
    /// (~/.local/share/claude/versions/2.1.270) still says what it is.
    nonisolated static func agentsByShell(_ shells: Set<pid_t>) -> [pid_t: String] {
        var out: [pid_t: String] = [:]
        guard !shells.isEmpty else { return out }
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return out }
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, Int32(PROC_PIDT_SHORTBSDINFO), 0, &info, size) == size else { continue }
            let parent = pid_t(info.pbsi_ppid)
            guard shells.contains(parent), out[parent] == nil else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            let name = (path as NSString).lastPathComponent
            if name == "claude" || path.contains("/claude/") { out[parent] = "claude" }
            else if name == "codex" || path.contains("/codex/") { out[parent] = "codex" }
        }
        return out
    }

    /// `pgrep -lfP <shell>` lists direct children as "<pid> <full command>";
    /// agents run as direct children of the shell whether typed or launched by us.
    nonisolated static func runningAgent(underShell pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-lfP", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            guard let sp = line.firstIndex(of: " ") else { continue }
            let cmd = line[line.index(after: sp)...]
            let exe = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let name = (exe as NSString).lastPathComponent
            if name == "claude" || name == "codex" { return name }
        }
        return nil
    }

    /// Current working directory of the shell, for session restore + context files.
    var currentCwd: String? {
        let pid = shellPid
        guard pid > 0 else { return lastReportedCwd }
        return Self.cwdOf(pid: pid) ?? lastReportedCwd
    }

    /// The kernel knows the shell's cwd; asking it costs microseconds, where
    /// spawning lsof costs ~100ms — and the board probes every tab every tick.
    nonisolated static func cwdOf(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, Int32(PROC_PIDVNODEPATHINFO), 0, &info, size) == size {
            var path = info.pvi_cdir.vip_path
            let s = withUnsafeBytes(of: &path) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            if !s.isEmpty { return s }
        }
        return cwdViaLsof(pid: pid)
    }

    nonisolated static func cwdViaLsof(pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    init(id: Int, opts: TabOptions) {
        self.id = id
        self.opts = opts
        self.emoji = opts.cwd != nil ? Emoji.forPath(opts.cwd) : "🔪"
        self.title = opts.shownTitle ?? opts.title ?? (opts.cwd.map { ($0 as NSString).lastPathComponent } ?? "shell \(id)")
        self.context = opts.context
        self.contextPinned = opts.contextPinned
        self.view = KnifeTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        lastActivity = opts.lastActivity
        view.processDelegate = self
        AppModel.shared.theme.style(terminal: view)

        var env = Self.shellEnv()
        env["KNIFE_TAB"] = String(id)
        let envList = env.map { "\($0.key)=\($0.value)" }

        let shell = Self.userShell()
        var cwd = opts.cwd ?? NSHomeDirectory()
        if !FileManager.default.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
        if let cmd = opts.cmd, TrustKeeper.runsClaude(cmd) { TrustKeeper.shared.settle(cwd) } // answer the trust prompt before it appears
        view.startProcess(executable: shell, args: ["-l"], environment: envList, execName: nil, currentDirectory: cwd)
        refreshRepoGroup() // before the first render, so a new tab lands in its group at once

        if let cmd = opts.cmd {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.view.send(txt: cmd + "\r")
            }
        }
        // Typing acknowledges a finished or waiting session. It doesn't mean Claude
        // stopped — clearing "working" on every key made a busy tab flap between
        // groups while you typed ahead. Esc and ^C do stop it, and an interrupt
        // sends no Stop hook, so those clear it.
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.lastActivity = Date()
            self.limited = false
            if self.status != .working { self.status = .idle }
            if self.attention { self.attention = false; AppModel.shared.tabStateChanged(self) }
        }
        view.onInterrupt = { [weak self] in
            self?.limited = false
            guard let self, self.working || self.status == .working else { return }
            self.working = false
            self.status = .idle
            AppModel.shared.tabStateChanged(self)
        }
        view.onBell = { [weak self] in
            guard let self else { return }
            AppModel.shared.bellRang(in: self)
        }
        view.onOutput = { [weak self] in
            guard let self else { return }
            AppModel.shared.sync?.tabOutput(self)
            ShellFollower.outputLanded(in: self)
        }
    }

    nonisolated static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, let s = String(validatingUTF8: sh), !s.isEmpty { return s }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Environment for spawned shells. The app inherits the environment of
    /// whatever launched it (Finder, Xcode, another terminal) — launched from
    /// Ghostty it carries TERM_PROGRAM=ghostty, GHOSTTY_*, and a TERMINFO that
    /// only has xterm-ghostty entries, and shell integrations keyed on those
    /// would think they're in Ghostty. Scrub the host's identity and set ours.
    static func shellEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDE_CODE_") && !$0.key.hasPrefix("GHOSTTY_")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "KnifeTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        env["TERMINFO"] = nil
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    func terminate() {
        view.process?.terminate()
    }
}

extension TabModel: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cols = newCols; self.rows = newRows
            AppModel.shared.sync?.tabOutput(self)
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !title.isEmpty else { return }
            if self.titleIsFixed {
                guard !self.contextPinned, let c = Self.contextLine(from: title, name: self.title, cwd: self.opts.cwd),
                      c != self.context else { return }
                self.context = c
            } else {
                self.title = title
            }
            AppModel.shared.tabStateChanged(self)
            AppModel.shared.saveSessionSoon()
        }
    }

    /// Claude Code titles the terminal with a short summary of the conversation ("✳ Fix the
    /// sidebar rename"). The glyph goes; a title that's just the program's or the shell's name,
    /// the tab's own name, or its directory says nothing and is ignored (the last real one stays).
    static func contextLine(from title: String, name: String, cwd: String?) -> String? {
        var s = title.trimmingCharacters(in: .whitespaces)
        while let f = s.first, !(f.isLetter || f.isNumber) { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let generic: Set<String> = ["claude code", "claude", "zsh", "bash", "fish", "sh", "-zsh", "-bash"]
        if generic.contains(s.lowercased()) || s.caseInsensitiveCompare(name) == .orderedSame { return nil }
        if let cwd, s == cwd || s == (cwd as NSString).abbreviatingWithTildeInPath || s.hasSuffix("/" + (cwd as NSString).lastPathComponent) { return nil }
        return s
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            if let directory, let url = URL(string: directory), url.isFileURL {
                self?.lastReportedCwd = url.path
                self?.refreshRepoGroup()
            }
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AppModel.shared.processExited(tabId: self.id)
        }
    }
}
