import AppKit
import SwiftUI
import Combine

@MainActor
final class KnifeWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var activeId: Int?
    @Published var showBoard = false
    var chatPanes = 0 // ChatPanes up (not their terminal fallback): a count, since tab switches overlap appear/disappear
    var chatShowing: Bool { chatPanes > 0 } // ⌘F/⌘G go to the chat's find bar
    /// The untouched shell a fresh window opens with; replaced by the first real tab.
    var defaultTabId: Int?
    /// The sidebar groups tabs; a tab changing group has to re-render the list
    /// itself, not just that row.
    private var statusWatch: [Int: AnyCancellable] = [:]

    var activeTab: TabModel? { tabs.first { $0.id == activeId } }

    /// Tabs in the order the sidebar draws them: by group, manual order within a
    /// group. ⌘1–9, ⌘⇧[ ] and the tab ⌘W lands on follow this, not `tabs` itself.
    var sidebarOrder: [TabModel] {
        SidebarGroup.allCases.flatMap { g in tabs.filter { $0.group == g } }
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
            tab.$group.dropFirst().removeDuplicates().map { _ in () },
            tab.$status.dropFirst().removeDuplicates().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
        AppModel.shared.tabOpened(tab, in: self)
        if activateIt { activate(tab.id) }
        return tab
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
