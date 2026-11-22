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
    var deferCmd = false      // restored dormant: cmd waits until the tab is opened (TabTier.defersRestore)
    var lastActivity: Date?   // restored from the session file, or now for a tab opened to work in
    var guest: String?       // a session shared with us (collaborative mode): mirrored tab id, no local process
}

enum TabStatus {
    case idle, working, ready, needsInput
}

@MainActor
final class TabModel: NSObject, ObservableObject, Identifiable {
    let id: Int
    let view: KnifeTermView
    @Published var emoji: String
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

    /// The agent command a dormant restored tab hasn't run yet: its shell is up, its agent isn't.
    private(set) var deferredCmd: String?

    /// Start the agent a dormant restored tab was holding back. False when there was nothing to start.
    @discardableResult
    func startDeferred() -> Bool {
        guard let cmd = deferredCmd else { return false }
        deferredCmd = nil
        view.send(txt: cmd + "\r")
        return true
    }

    /// Run `deliver` when this tab's agent can take it: at once, or — for a dormant tab that hadn't
    /// started its agent — after starting it and seeing its process come up. The command line goes
    /// in first, so what's delivered can't land on the bare shell prompt; if the agent never comes
    /// up it's dropped rather than run as a shell command.
    func whenAgentUp(_ deliver: @escaping () -> Void) {
        guard startDeferred() else { deliver(); return }
        let pid = shellPid
        Task { @MainActor in
            for _ in 0..<60 where Self.agentsByShell([pid])[pid] == nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard Self.agentsByShell([pid])[pid] != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // its input box isn't up the instant its process is
            deliver()
        }
    }

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

        var env = Self.shellEnvironment()
        env["KNIFE_TAB"] = String(id)
        let envList = env.map { "\($0.key)=\($0.value)" }

        let shell = Self.userShell()
        var cwd = opts.cwd ?? NSHomeDirectory()
        if !FileManager.default.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
        if opts.guest == nil {
            if let cmd = opts.cmd, TrustKeeper.runsClaude(cmd) { TrustKeeper.shared.settle(cwd) } // answer the trust prompt before it appears
            view.startProcess(executable: shell, args: ["-l"], environment: envList, execName: nil, currentDirectory: cwd)
        }
        refreshRepoGroup() // before the first render, so a new tab lands in its group at once

        if let cmd = opts.cmd, opts.guest == nil {
            if opts.deferCmd {
                deferredCmd = cmd
                sessionId = TabTier.resumedSession(in: cmd)   // "resume chat" finds this tab instead of opening a second one
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.view.send(txt: cmd + "\r")
                }
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
            if self.askIdle != nil { self.armAsk() } // a key while a question is up restarts its idle clock
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
            if self.sessionPid == 0 { self.sessionPid = self.shellPid } // remembered for terminate(), when the shell may already be gone
            AppModel.shared.sync?.tabOutput(self)
            ShellFollower.outputLanded(in: self)
        }
    }

    /// What a shell we start inherits, for tabs and mini terminals alike: the launcher's
    /// terminal identity scrubbed (launched from Ghostty the app inherits
    /// TERM_PROGRAM=ghostty, GHOSTTY_*, and a TERMINFO with only xterm-ghostty —
    /// shell integrations keyed on those would misfire).
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && !$0.key.hasPrefix("GHOSTTY_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "KnifeTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        env["TERMINFO"] = nil
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["KNIFE_SOCK"] = Instance.socketPath        // hooks and knife-job.sh answer this app
        if let dir = Instance.claudeConfigDir { env["CLAUDE_CONFIG_DIR"] = dir }  // `claude` here is this app's account
        return env
    }

    nonisolated static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, let s = String(validatingUTF8: sh), !s.isEmpty { return s }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Everything started in this tab is in the shell's session, even helpers that
    /// were reparented to launchd. SwiftTerm only signals the shell, so a helper
    /// that never handles SIGHUP (a busy-looping MCP server) outlives the tab.
    /// Session, not tty: once the shell exits the kernel detaches the tty from
    /// what it left behind, but the session id stays.
    private var sessionPid: pid_t = 0
    static func pids(inSession sid: pid_t) -> [pid_t] {
        guard sid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 && getsid($0) == sid }
    }

    func terminate() {
        if sessionPid == 0 { sessionPid = shellPid }
        Self.terminate(view.process, session: sessionPid)
    }

    /// Hang up a shell and make sure nothing it started outlives it (tabs and mini terminals).
    static func terminate(_ process: LocalProcess?, session sid: pid_t) {
        let left = pids(inSession: sid)
        let shell = process?.running == true ? process?.shellPid ?? 0 : 0
        process?.terminate()
        // SwiftTerm's terminate sends the shell SIGTERM, which an interactive zsh ignores, then
        // stops watching it — so a closed tab's shell, its claude and every MCP server under it
        // lived on with no tab (41 of them after a day). SIGHUP is what a closing terminal means:
        // zsh exits and takes its jobs with it. Then reap it (SwiftTerm no longer does), or each
        // closed tab leaves a zombie. Only while it was still running: an exited shell was reaped.
        if shell > 0 {
            kill(shell, SIGHUP)
            DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; waitpid(shell, &status, 0) }
        }
        guard !left.isEmpty else { return }
        // Give them 2s to exit on SIGHUP, then SIGKILL whatever is left. A
        // detached sh, so the sweep still runs when the app itself is quitting.
        // ponytail: kills by pid after 2s (pid reuse is theoretically possible), and
        // takes nohup'd jobs with it; re-check the session per pid if either ever bites.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; kill -9 \(left.map(String.init).joined(separator: " ")) 2>/dev/null"]
        try? p.run()
    }

    // ─── Question auto-continue: an AskUserQuestion nobody touches for `questionTimeout` seconds
    // (default 300; `defaults write com.cwandt.knifeterminal questionTimeout -float 0` turns it off)
    // takes its first option — the recommended one — like Claude Code's own idle timeout, which
    // never runs under Remote Control. Only a picker whose options end in "Chat about this" is
    // answered, so permission prompts are never touched.
    private var askIdle: DispatchWorkItem?
    private var askPending = false
    @Published var askDeadline: Date? // when the pending question auto-picks; the footer counts down to it
    static var questionTimeout: TimeInterval { UserDefaults.standard.object(forKey: "questionTimeout") as? Double ?? 300 }

    func askStarted() { askPending = true; armAsk() }
    func askEnded() { askPending = false; askIdle?.cancel(); askIdle = nil; askDeadline = nil }

    private func armAsk() {
        askIdle?.cancel(); askDeadline = nil
        guard askPending, Self.questionTimeout > 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.askIdle = nil; self?.askDeadline = nil; self?.autoAnswer(ticks: 6, last: nil) }
        askIdle = w
        askDeadline = Date(timeIntervalSinceNow: Self.questionTimeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.questionTimeout, execute: w)
    }

    /// 1 picks the first option (a lone single-select submits on it); a later question or the
    /// review screen follows a second later, where 1 picks or submits again. ponytail: a
    /// multi-select question shows the same title after the toggle, so the loop stops there.
    private func autoAnswer(ticks: Int, last: String?) {
        guard askPending, ticks > 0, let p = ScreenPrompt.parse(view.plainScreen()),
              p.options.last?.hasPrefix("Chat about this") == true || p.options.first == "Submit answers", // the review screen
              p.title != last else { return }
        view.send(txt: "1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoAnswer(ticks: ticks - 1, last: p.title) }
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
