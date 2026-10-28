import AppKit
import SwiftUI
import Combine

@MainActor
final class KnifeWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var tabs: [TabModel] = [] { didSet { regroup() } }
    @Published var activeId: Int?
    @Published var showBoard = false
    var chatPanes = 0 // ChatPanes up (not their terminal fallback): a count, since tab switches overlap appear/disappear
    var chatShowing: Bool { chatPanes > 0 } // ⌘F/⌘G go to the chat's find bar
    /// The untouched shell a fresh window opens with; replaced by the first real tab.
    var defaultTabId: Int?
    /// The sidebar groups tabs by repo and ranks the groups by status; a tab changing
    /// either has to re-render the list itself, not just that row.
    private var statusWatch: [Int: AnyCancellable] = [:]
    /// The sidebar's tab groups exactly as drawn (TabGroups.sections). Stored, not computed:
    /// group order depends on lastActivity, which moves on every keystroke without telling
    /// anyone, so a computed order could differ from the one on screen. regroup() is the
    /// only writer: on a tab added, closed or moved, a tab's repo or status changing, the
    /// freeze, and the app's 15 s timer.
    @Published private(set) var tabSections: [TabSection] = []
    /// Set while the pointer is over the tab list (see TabGroupFreeze).
    private var tabFreeze: TabGroupFreeze?

    var activeTab: TabModel? { tabs.first { $0.id == activeId } }

    /// Tabs in the order the sidebar draws them, folded groups included. ⌘1–9, ⌘⇧[ ]
    /// and the tab ⌘W lands on follow this, not `tabs` itself.
    var sidebarOrder: [TabModel] {
        let byId = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return tabSections.flatMap(\.ids).compactMap { byId[$0] }
    }

    func regroup() {
        let next = TabGroups.sections(tabs.map(\.groupMember), frozen: tabFreeze)
        if next != tabSections { tabSections = next }
    }

    /// The sidebar's hover: freeze what's on screen, or let it catch up.
    func freezeTabGroups(_ on: Bool) {
        tabFreeze = on ? TabGroupFreeze(tabSections) : nil
        regroup()
    }

    /// The app's 15 s timer: pick up a cd the shell didn't announce, and re-rank groups whose
    /// recency typing has changed.
    func refreshTabGroups() {
        for t in tabs { t.refreshRepoGroup() }
        regroup()
    }

    convenience init(bounds: NSRect?) {
        let rect = bounds ?? NSRect(x: 0, y: 0, width: 1100, height: 700)
        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.tabbingMode = .disallowed
        win.minSize = NSSize(width: 400, height: 240)
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        win.backgroundColor = AppModel.shared.theme.nsColor(AppModel.shared.theme.current.background)
        win.contentView = NSHostingView(rootView: ContentView(controller: self))
        if bounds != nil { win.setFrame(rect, display: true) } else { win.center() }
    }

    @discardableResult
    func addTab(_ opts: TabOptions = TabOptions(), activateIt: Bool = true) -> TabModel {
        let tab = TabModel(id: AppModel.shared.takeTabId(), opts: opts)
        tabs.append(tab)
        statusWatch[tab.id] = Publishers.Merge(
            Publishers.Merge3(
                tab.$repoGroup.dropFirst().removeDuplicates().map { _ in () },
                tab.$attention.dropFirst().removeDuplicates().map { _ in () },
                tab.$working.dropFirst().removeDuplicates().map { _ in () }),
            tab.$status.dropFirst().removeDuplicates().map { _ in () })
            // @Published fires in willSet, before the tab holds the new value: regroup after it lands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.regroup(); self?.objectWillChange.send() }
        AppModel.shared.tabOpened(tab, in: self)
        if activateIt { activate(tab.id) }
        return tab
    }

    /// The footer's claude on/off switch: whether ⌘T, Shell › New Tab and "+ new tab" start
    /// `claude`. On until switched off.
    static var autoClaude: Bool { UserDefaults.standard.object(forKey: "autoClaude") as? Bool ?? true }

    /// A tab asked for by hand. Claude starts where a plain shell would, and comes back on relaunch
    /// the way a project's claude tab does: its own chat once the hooks have named it, else `claude -c`.
    func newTab(claude: Bool) {
        addTab(claude ? TabOptions(cmd: "claude", restoreCmd: "claude -c", lastActivity: Date()) : TabOptions())
    }

    func activate(_ id: Int) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        activeId = id
        if NSApp.isActive, window?.isKeyWindow ?? false, t.attention {
            t.attention = false
            t.status = t.working ? .working : .idle
        }
        AppModel.shared.saveSessionSoon()
    }

    func closeTab(_ id: Int, keepAlive: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let shown = sidebarOrder
        let pos = shown.firstIndex { $0.id == id } ?? 0
        let tab = tabs.remove(at: idx)
        statusWatch.removeValue(forKey: id)
        if !keepAlive {
            tab.terminate()
            AppModel.shared.tabClosed(tab)
        }
        if tabs.isEmpty {
            if keepAlive || AppModel.shared.windows.count > 1 {
                window?.close()
            } else {
                addTab()
                defaultTabId = activeId
            }
            return
        }
        if activeId == id {
            // The row below it in the sidebar takes over (the one above, if it was last).
            let rest = shown.filter { $0.id != id }
            activate(rest[min(pos, rest.count - 1)].id)
        }
        AppModel.shared.saveSessionSoon()
    }

    /// Put text where you're typing in the active tab, without sending it (sidebar prompts and
    /// clips). Chat view up → its composer's draft. Claude Code → typed, since it reads a fast
    /// burst as a paste and tags it <pasted_content> (see typeLine). Anything else → pasted.
    func insertIntoActiveTab(_ text: String) {
        guard let tab = activeTab, !text.isEmpty else { return }
        if chatShowing && !showBoard {
            NotificationCenter.default.post(name: .knifeChatInsert, object: self, userInfo: ["text": text])
            return
        }
        // by executable path in one pass over the process table: claude renames its process to
        // its version, and claudeRunning's pgrep is a subprocess
        let pid = tab.shellPid
        if pid > 0, TabModel.agentsByShell([pid])[pid] == "claude" { tab.view.typeText(text) } else { tab.view.pasteText(text) }
        if let w = window, tab.view.window === w { w.makeFirstResponder(tab.view) }
    }

    func moveTab(_ id: Int, before targetId: Int) {
        guard id != targetId,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        AppModel.shared.saveSessionSoon()
    }

    func cycle(_ dir: Int) {
        let order = sidebarOrder
        guard let cur = activeId, let i = order.firstIndex(where: { $0.id == cur }) else { return }
        activate(order[(i + dir + order.count) % order.count].id)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.windowClosing(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let t = activeTab, t.attention {
            t.attention = false
            t.status = t.working ? .working : .idle
        }
        AppModel.shared.mostRecentWindow = self
    }

    func windowDidMove(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
    func windowDidResize(_ notification: Notification) { AppModel.shared.saveSessionSoon() }
}
