import SwiftUI
import AppKit
import KnifeKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let knifeFocusSearch = Notification.Name("knife.focusSearch")
    static let knifeChatFind = Notification.Name("knife.chatFind") // object: window controller; userInfo["action"]: NSTextFinder.Action
    static let knifeToggleSidebar = Notification.Name("knife.toggleSidebar")
    static let knifeChatInsert = Notification.Name("knife.chatInsert") // object: window controller; userInfo["text"]: String
}

// Chrome type: Helvetica Now Text (system-installed); the terminal grid stays monospace.
func ui(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "HelveticaNowText-Medium" : "HelveticaNowText-Regular", size: size)
}

// Upstream's chat view and git panel are set in Space Mono.
func mono(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? "Space Mono Bold" : "Space Mono", size: size)
}

struct ContentView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @AppStorage("sidebarCollapsed") private var collapsed = false
    @AppStorage("sideWidth") private var sideWidth: Double = 220
    @AppStorage("gitPanel") private var gitPanel = false
    @AppStorage("chatView") private var chatView = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !collapsed {
                    SidebarView(controller: controller)
                        .frame(width: max(160, min(480, sideWidth)))
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .overlay(
                            Rectangle().fill(Color.clear).frame(width: 7)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { v in sideWidth = max(160, min(480, v.location.x)) })
                                // set(), not push/pop: an unmatched pop when the view redraws mid-hover
                                // leaves the wrong cursor stuck app-wide
                                .onContinuousHover { phase in
                                    if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                                }
                        )
                }
                Group {
                    if controller.showBoard {
                        BoardView(controller: controller)
                    } else if chatView, let tab = controller.activeTab {
                        ChatPane(controller: controller, tab: tab)
                            .id(tab.id) // fresh state per tab: echoes, opened runs, find never carry over
                    } else {
                        TerminalPane(controller: controller)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) { if !controller.showBoard { PromptRail(controller: controller) } } // floats: no reflow
                if gitPanel {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    GitPanel(controller: controller).frame(width: 280)
                }
            }
            FooterBar(controller: controller)
        }
        .background(bg)
        .ignoresSafeArea()
    }

    private var bg: Color { Color(nsColor: theme.nsColor(theme.current.background)) }
}

// ─── Terminal host: shows the active tab's NSView ───

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var controller: KnifeWindowController

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tab = controller.activeTab else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let tv = tab.view
        if tv.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            tv.frame = container.bounds
            tv.autoresizingMask = [.width, .height]
            container.addSubview(tv)
        }
        DispatchQueue.main.async {
            if let w = tv.window, w.firstResponder !== tv, w.isKeyWindow {
                w.makeFirstResponder(tv)
            }
        }
    }
}

// ─── Sidebar ───

struct SidebarView: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @State private var projects: [Project] = []
    @State private var meta = Projects.SidebarMeta()
    @State private var sectioned: [(ProjectSection, [Project])] = []
    @State private var elsewhere: [Project] = []   // in the manifest, checked out only on another Mac
    @State private var query = ""
    @State private var drag: SidebarDrag?
    @State private var hoverSection: ProjectSection?
    /// The sidebar's folders. A project drag files into them as it goes (like `sectioned`) and
    /// endDrag saves what's on screen.
    @State private var tree = FolderTree()
    /// Where a dragged folder would land if let go now, or the folder a project is held over.
    @State private var folderSpot: FolderSpot?
    @State private var naming: FolderNaming?
    @State private var folderNameText = ""
    @AppStorage("knife.collapsedSections") private var collapsedRaw = ""
    @AppStorage("knife.collapsedFolders") private var collapsedFoldersRaw = ""
    @AppStorage("knife.expandedProjects") private var expandedRaw = ""   // see ExpandedProjects
    /// project path → its recent chats, for expanded projects only. Read off the main thread, never in body.
    @State private var chats: [String: [RecentChat]] = [:]
    @AppStorage("autoClaude") private var autoClaude = true
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var renamingTab: TabModel?
    @State private var tabNameText = ""
    @State private var tabContextText = ""
    /// tab id → the group it was in when the pointer arrived over the tab list.
    @State private var frozen: [Int: SidebarGroup]? = nil
    @State private var activeRepo: RepoKey?   // the active tab's, for its prompt section
    @State private var pointerInside = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // room for traffic lights

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // Tabs grouped (needs input first); manual order kept within a group.
                    // Headers only appear once something isn't dormant, so a window of
                    // plain shells looks like a plain list.
                    VStack(alignment: .leading, spacing: 1) {
                        let grouped = SidebarGroup.allCases.map { g in
                            (g, controller.tabs.filter { shownGroup($0) == g })
                        }
                        let showHeaders = grouped.contains { $0.0 != .dormant && !$0.1.isEmpty }
                        ForEach(grouped, id: \.0) { group, tabs in
                            if !tabs.isEmpty {
                                if showHeaders { tabGroupHeader(group, count: tabs.count) }
                                ForEach(tabs) { tab in tabRow(tab) }
                            }
                        }
                    }
                    // While the pointer is over the tabs, nothing changes group: rows never
                    // move under a click, and a press isn't turned into a drag by a row
                    // sliding away. Dots and status words keep updating live.
                    .onHover { inside in
                        if inside {
                            frozen = Dictionary(controller.tabs.map { ($0.id, $0.group) }, uniquingKeysWith: { a, _ in a })
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { frozen = nil }
                        }
                    }
                    // claude or a plain shell per the footer switch; shift-click for a plain shell once
                    Button(action: { controller.newTab(claude: autoClaude && !NSEvent.modifierFlags.contains(.shift)) }) {
                        HStack(spacing: 6) {
                            Text("+").font(ui(12))
                            Text("new tab").font(ui(11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(autoClaude ? "new tab running claude  ⌘T\nshift-click or ⌥⌘T for a plain shell · right-click to choose"
                                     : "new tab, plain shell  ⌘T — claude is off in the footer\nright-click to choose")
                    // either way, whatever the switch says; ⌘T is only shown where it applies
                    .contextMenu {
                        Button("new claude tab") { controller.newTab(claude: true) }
                            .keyboardShortcut(autoClaude ? KeyboardShortcut("t", modifiers: .command) : nil)
                        Button("new plain shell") { controller.newTab(claude: false) }
                            .keyboardShortcut("t", modifiers: [.command, .option])
                    }

                    PromptSections(controller: controller, repo: activeRepo)

                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                        .padding(.vertical, 6)

                    TextField("⌘K search projects", text: $query)
                        .textFieldStyle(.plain)
                        .font(ui(11))
                        .focused($searchFocused)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                        .onSubmit {
                            if let first = query.trimmingCharacters(in: .whitespaces).isEmpty
                                ? projects.first : filtered.first {
                                open(project: first)
                            }
                        }
                        .onExitCommand { query = ""; searchFocused = false }

                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Headers are always rendered: revealing them only while dragging
                        // reflowed the whole list the instant a row was picked up, so the
                        // row under the cursor was no longer the one you grabbed.
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(ProjectSection.allCases, id: \.self) { section in
                                let rows = projects(in: section)
                                let byPath = Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                                sectionHeader(section)
                                    .onDrop(of: [.text], delegate: ProjectSectionDrop(
                                        target: section, drag: $drag,
                                        hoverSection: $hoverSection, folderSpot: $folderSpot,
                                        canMove: tree.canMove(_:to:),
                                        liveMove: liveMove(_:into:),
                                        end: endDrag))
                                if !isCollapsed(section) {
                                    ForEach(tree.lines(in: section, paths: rows.map(\.path), collapsed: isFolderCollapsed)) { line in
                                        switch line {
                                        case .folder(let f, let depth, let count):
                                            folderHeader(f, depth: depth, count: count)
                                        case .project(let path, let depth):
                                            if let p = byPath[path] { sectionRow(p, in: section, depth: depth) }
                                        }
                                    }
                                }
                            }
                        }
                        // the list's own right-click (rows and headers have theirs): folders from disk
                        .contentShape(Rectangle())
                        .contextMenu { rootsMenu }
                    } else {
                        ForEach(filtered) { p in projectRow(p) }
                    }
                    // manifest projects that only exist on another Mac — open = clone here
                    ForEach(filteredElsewhere) { p in
                        Button(action: { AppModel.shared.openProject(p.path, cmd: "claude"); query = ""; searchFocused = false }) {
                            HStack(spacing: 6) {
                                Text(Emoji.forPath(p.path)).font(.system(size: 12))
                                Text(p.name).font(ui(11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("clone").font(ui(9))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("on another Mac — opens by cloning it here")
                        .contextMenu { projectMenu(p, local: false) }
                    }

                    JobBox()
                }
                .padding(.vertical, 4)
            }
            .onHover { inside in
                pointerInside = inside
                if !inside { refreshChats() } // what was held while the pointer was here catches up
            }

        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            endDrag()
            return true
        }
        .onAppear { rebuild(); refreshRepo() }
        .onChange(of: controller.activeId) { refreshRepo() }
        .alert(naming?.title ?? "", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("name", text: $folderNameText)
            Button("save") { commitFolderName() }
            Button("cancel", role: .cancel) { naming = nil }
        } message: {
            Text("a folder in the sidebar only — nothing on disk changes")
        }
        // A hover exit never arrives if you leave the app with the pointer parked on
        // the tabs; don't leave the list frozen until the mouse moves again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            frozen = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            rebuildIfIdle()
            refreshRepo()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in // manifest syncs every ~10s
            rebuildIfIdle()
            // a cd into or out of a repo shows up here; not while the pointer is over the sidebar,
            // where the repo section appearing would slide every row below it under the pointer
            if !pointerInside { refreshRepo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .knifeFocusSearch)) { _ in
            if controller.window?.isKeyWindow ?? false { searchFocused = true }
        }
        .alert("rename tab", isPresented: Binding(
            get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })) {
            TextField("name", text: $tabNameText)
            TextField("context", text: $tabContextText, prompt: Text("context — Claude fills this in as it works"))
            Button("save") { commitTabRename() }
            Button("cancel", role: .cancel) { renamingTab = nil }
        } message: {
            Text(renamingTab?.opts.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
        }
        .alert("rename project", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $renameText)
            Button("save") { commitRename() }
            Button("cancel", role: .cancel) { renaming = nil }
        } message: {
            Text(renaming.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
        }
    }

    /// Right-click a project that only exists on another Mac: its repo's web page (from the
    /// manifest's remote). Local rows get the same links inside ProjectRow's own menu.
    @ViewBuilder
    private func projectMenu(_ p: Project, local: Bool) -> some View {
        ProjectRow.links(p, local: local)
    }

    private var filtered: [Project] { filter(projects) }
    private var filteredElsewhere: [Project] { filter(elsewhere) }

    private func filter(_ list: [Project]) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private func tabRow(_ tab: TabModel) -> some View {
        TabRow(tab: tab, active: tab.id == controller.activeId,
               activate: { controller.activate(tab.id) },
               close: { controller.closeTab(tab.id) },
               rename: { startTabRename(tab) })
            .opacity(drag == .tab(tab.id) ? 0.4 : 1.0)
            .onDrag {
                let id = tab.id
                // Deferred: writing state inside onDrag re-renders the row while
                // AppKit is opening the drag session, which cancels it.
                DispatchQueue.main.async { drag = .tab(id) }
                return NSItemProvider(object: String(id) as NSString)
            }
            .onDrop(of: [.text], delegate: TabReorderDrop(
                targetId: tab.id, drag: $drag, controller: controller,
                sameGroup: sameShownGroup, end: endDrag))
    }

    /// The group a row is drawn in: frozen while the pointer is over the tab list,
    /// live otherwise. Drags compare this, so they match what's on screen.
    private func shownGroup(_ tab: TabModel) -> SidebarGroup { frozen?[tab.id] ?? tab.group }

    private func sameShownGroup(_ a: Int, _ b: Int) -> Bool {
        guard let ta = controller.tabs.first(where: { $0.id == a }),
              let tb = controller.tabs.first(where: { $0.id == b }) else { return false }
        return shownGroup(ta) == shownGroup(tb)
    }

    private func tabGroupHeader(_ group: SidebarGroup, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(group.rawValue)
                .foregroundStyle(group == .needsInput ? theme.attentionColor : Color.secondary)
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(ui(10))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func projects(in section: ProjectSection) -> [Project] {
        sectioned.first { $0.0 == section }?.1 ?? []
    }

    /// `expand`: the row's disclosure; nil leaves it off (search results).
    private func projectRow(_ p: Project, depth: Int = 0, expand: (() -> Void)? = nil) -> some View {
        ProjectRow(project: p, starred: meta.byPath[p.path]?.starred ?? false,
                   indent: Self.indent(depth),
                   folder: meta.tree?.place[p.path].flatMap { meta.tree?.folder($0)?.name },
                   expanded: expand != nil && isExpanded(p.path),
                   toggleExpand: expand,
                   open: { open(project: p) },
                   openChat: { open(project: p, cmd: $0) },
                   toggleStar: { toggleStar(p) },
                   move: { move(p, to: $0) },
                   rename: { renameText = p.name; renaming = p },
                   unfile: { saveTree { $0.file(p.path, into: nil) } })
    }

    /// A project in its section (or one of the section's folders), draggable, with its recent
    /// chats under it when expanded. One unit in the list, so the chats travel with a dragged
    /// project; only the project row itself is a drag source and a place to drop beside.
    private func sectionRow(_ p: Project, in section: ProjectSection, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            projectRow(p, depth: depth, expand: { toggleExpanded(p.path) })
                .onDrag {
                    let path = p.path
                    DispatchQueue.main.async { drag = .project(path) }
                    return NSItemProvider(object: "proj:\(path)" as NSString)
                }
                .onDrop(of: [.text], delegate: ProjectRowDrop(
                    targetPath: p.path, targetSection: section,
                    drag: $drag,
                    liveMove: liveMove(_:before:in:),
                    end: endDrag))
            if isExpanded(p.path) { chatRows(p, depth: depth + 1) }
        }
        .opacity(drag == .project(p.path) || draggedFolderHolds(tree.folder(of: p.path, in: section)) ? 0.4 : 1.0)
    }

    /// An expanded project's recent chats. Nothing until the first read lands — better than a
    /// "no chats yet" that flips to a list. A drop here only ends the drag, like anywhere else.
    @ViewBuilder
    private func chatRows(_ p: Project, depth: Int) -> some View {
        if let list = chats[p.path] {
            VStack(alignment: .leading, spacing: 1) {
                if list.isEmpty {
                    Text("no chats yet").font(ui(11)).foregroundStyle(.tertiary)
                        .padding(.leading, 10 + Self.indent(depth)).padding(.trailing, 10).padding(.vertical, 3)
                }
                ForEach(list) { c in
                    ChatRow(chat: c, isOpen: AppModel.shared.tab(session: c.id) != nil, indent: Self.indent(depth),
                            resume: { ProjectChatsMenu.resume(c.id) { open(project: p, cmd: $0) } })
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: EndDragDrop(drag: $drag, end: endDrag))
        }
    }

    static let chatLimit = 8

    private func isExpanded(_ path: String) -> Bool { ExpandedProjects.parse(expandedRaw).contains(path) }

    private func toggleExpanded(_ path: String) {
        let opening = !isExpanded(path)
        expandedRaw = ExpandedProjects.toggled(path, in: expandedRaw)
        if opening { loadChats([path]) } else { chats[path] = nil }
    }

    /// No pointer on the sidebar and no drag: rows below may change.
    private var sidebarIdle: Bool { !pointerInside && drag == nil }

    /// Re-reads the expanded projects' chats. While the pointer is on the sidebar only the ones
    /// with nothing loaded yet are read: rows never appear, vanish or reorder under it.
    private func refreshChats() {
        loadChats(ExpandedProjects.toLoad(expanded: ExpandedProjects.parse(expandedRaw), listed: projects.map(\.path),
                                          loaded: Set(chats.keys), idle: sidebarIdle))
    }

    /// Lists and titles the chats off the main thread. A result that lands once the pointer is on
    /// the sidebar only fills a project that had nothing; the rest wait for the next idle refresh.
    private func loadChats(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let limit = Self.chatLimit
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                paths.map { ($0, RecentChats.list(cwd: $0, limit: limit)) }
            }.value
            for (path, list) in loaded where isExpanded(path) && (sidebarIdle || chats[path] == nil) {
                if chats[path] != list { chats[path] = list }
            }
        }
    }

    private static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 12 }
    /// Fixed so a folder dragged over one can tell its top, middle and bottom apart.
    static let folderRowHeight: CGFloat = 21

    private func folderHeader(_ f: SidebarFolder, depth: Int, count: Int) -> some View {
        let shut = isFolderCollapsed(f.id)
        return HStack(spacing: 6) {
            Text(shut ? "▸" : "▾").font(ui(10)).foregroundStyle(.tertiary).frame(width: 14)
            Text(f.name).font(ui(11)).foregroundStyle(.secondary).lineLimit(1)
            if shut { Text("\(count)").font(ui(10)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + Self.indent(depth)).padding(.trailing, 10)
        .frame(height: Self.folderRowHeight)
        // drop feedback draws over the row, never beside it: nothing reflows mid-drag
        .background(folderSpot == .into(f.id) ? theme.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .top) {
            if folderSpot == .before(f.id) { Rectangle().fill(theme.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            if folderSpot == .after(f.id) { Rectangle().fill(theme.accentColor).frame(height: 2) }
        }
        .opacity(draggedFolderHolds(f.id) ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { toggleFolder(f.id) }
        .contextMenu {
            Button("new folder") { startNaming(.new(f.section, parent: f.id)) }
            Button("rename…") { startNaming(.rename(f)) }
            Button("delete “\(f.name)”") { deleteFolder(f.id) }
        }
        .help("a sidebar folder — drag projects onto it; drag it to reorder or nest")
        .onDrag {
            let id = f.id
            DispatchQueue.main.async { drag = .folder(id) }
            return NSItemProvider(object: "folder:\(id)" as NSString)
        }
        .onDrop(of: [.text], delegate: FolderDrop(
            folder: f, open: !shut, drag: $drag, spot: $folderSpot,
            canMove: tree.canMove(_:to:),
            fileInto: liveMove(_:intoFolder:),
            end: endDrag))
    }

    /// The folder being dragged is `id` or holds it, so it dims with the rest of what's moving.
    private func draggedFolderHolds(_ id: String?) -> Bool {
        guard case .folder(let dragged) = drag, let id else { return false }
        return tree.isInside(id, dragged)
    }

    /// Adding and removing folders from disk: the project list's own right-click and each
    /// section's. Only folders added here can be removed; the built-in code roots can't.
    @ViewBuilder
    private var rootsMenu: some View {
        Button("add folder from disk…", action: addRoot)
        let roots = meta.roots ?? []
        if !roots.isEmpty { Divider() }
        ForEach(roots, id: \.self) { r in
            Button("remove “\(rootLabel(r, among: roots))” from sidebar") { removeRoot(r) }
        }
    }

    private func rootLabel(_ r: String, among roots: [String]) -> String {
        let name = (r as NSString).lastPathComponent
        let twins = roots.filter { ($0 as NSString).lastPathComponent == name }.count
        return twins > 1 ? (r as NSString).abbreviatingWithTildeInPath : name
    }

    private func sectionHeader(_ section: ProjectSection) -> some View {
        HStack(spacing: 4) {
            Text(section == .starred ? "★" : section.rawValue)
                .foregroundStyle(.secondary)
            if isCollapsed(section) {
                Text("▸ \(projects(in: section).count)")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(ui(10))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(hoverSection == section ? theme.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapse(section) }
        .contextMenu {
            Button("new folder") { startNaming(.new(section, parent: nil)) }
            Divider()
            rootsMenu
        }
    }

    private func isFolderCollapsed(_ id: String) -> Bool {
        collapsedFoldersRaw.split(separator: ",").contains(Substring(id))
    }

    private func toggleFolder(_ id: String) { setFolder(id, collapsed: !isFolderCollapsed(id)) }

    private func setFolder(_ id: String, collapsed: Bool) {
        var set = Set(collapsedFoldersRaw.split(separator: ",").map(String.init))
        if collapsed { set.insert(id) } else { set.remove(id) }
        collapsedFoldersRaw = set.sorted().joined(separator: ",")
    }

    private func startNaming(_ n: FolderNaming) {
        if case .rename(let f) = n { folderNameText = f.name } else { folderNameText = "new folder" }
        naming = n
    }

    private func commitFolderName() {
        guard let n = naming else { return }
        naming = nil
        let name = folderNameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch n {
        case .new(let section, let parent):
            // open the way to it, so the new folder is on screen
            if isCollapsed(section) { toggleCollapse(section) }
            if let parent { setFolder(parent, collapsed: false) }
            saveTree { $0.add(name, in: section, parent: parent) }
        case .rename(let f):
            saveTree { $0.rename(f.id, to: name) }
        }
    }

    private func deleteFolder(_ id: String) {
        setFolder(id, collapsed: false) // forget its fold state with it
        saveTree { $0.delete(id) }
    }

    /// A change to the saved folders outside a drag: on the saved tree, not the live one.
    private func saveTree(_ change: (inout FolderTree) -> Void) {
        var next = Projects.loadMeta()
        var t = next.tree ?? FolderTree()
        change(&t)
        next.tree = t
        Projects.saveMeta(next)
        rebuild()
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Add to Sidebar"
        panel.message = "The projects inside this folder are listed in the sidebar. Nothing in it is changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = Projects.canonRoot(url.path)
        var next = Projects.loadMeta()
        let listed = (Projects.builtInRoots + (next.roots ?? [])).map(Projects.canonRoot)
        guard !listed.contains(dir) else { NSSound.beep(); return } // already scanned
        next.roots = (next.roots ?? []) + [dir]
        Projects.saveMeta(next)
        rebuild()
    }

    /// Forgets the folder; nothing on disk is touched.
    private func removeRoot(_ root: String) {
        var next = Projects.loadMeta()
        next.roots?.removeAll { $0 == root }
        Projects.saveMeta(next)
        rebuild()
    }

    private func isCollapsed(_ section: ProjectSection) -> Bool {
        collapsedRaw.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func toggleCollapse(_ section: ProjectSection) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if !set.insert(section.rawValue).inserted { set.remove(section.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    private func refreshRepo() {
        let next = controller.activeTab?.currentCwd.flatMap(Repos.key(for:))
        if next != activeRepo { activeRepo = next }
    }

    private func rebuild() {
        meta = Projects.loadMeta()
        let (local, remote) = Manifest.sidebarProjects()
        projects = local.map { p in
            guard let n = meta.byPath[p.path]?.name, !n.isEmpty else { return p }
            return Project(path: p.path, name: n, t: p.t)
        }
        elsewhere = remote
        sectioned = Projects.sectioned(projects, meta: meta)
        tree = meta.tree ?? FolderTree()
        refreshChats()
    }

    /// The timer's and window focus's rebuild, held off mid-drag: it would reset the live order
    /// and pull the row you're holding back to where it started. A drag can't outlast the mouse
    /// button, so one still set with the button up was let go outside the window: end it the
    /// way any drop ends, keeping what's on screen.
    private func rebuildIfIdle() {
        if drag != nil {
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            endDrag()
        }
        rebuild()
    }

    private func startTabRename(_ tab: TabModel) {
        tabNameText = tab.title
        tabContextText = tab.contextPinned ? (tab.context ?? "") : ""
        renamingTab = tab
    }

    /// A typed context sticks until it's cleared; cleared, the terminal's titles take over again.
    private func commitTabRename() {
        guard let tab = renamingTab else { return }
        renamingTab = nil
        let name = tabNameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != tab.title { tab.title = name; tab.renamed = true }
        let ctx = tabContextText.trimmingCharacters(in: .whitespaces)
        if ctx.isEmpty {
            if tab.contextPinned { tab.context = nil }
            tab.contextPinned = false
        } else {
            tab.context = ctx
            tab.contextPinned = true
        }
        AppModel.shared.tabStateChanged(tab)
        AppModel.shared.saveSessionSoon()
    }

    private func commitRename() {
        guard let p = renaming else { return }
        var next = meta
        var saved = next.byPath[p.path] ?? ProjectMeta()
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        saved.name = (trimmed.isEmpty || trimmed == (p.path as NSString).lastPathComponent) ? nil : trimmed
        next.byPath[p.path] = saved
        Projects.saveMeta(next)
        renaming = nil
        rebuild()
    }

    /// A fresh `claude` restores as `claude -c`; `claude -c` and `claude --resume <id>` restore as themselves.
    private func open(project p: Project, cmd: String = "claude") {
        Projects.touch(p.path)
        controller.addTab(TabOptions(cwd: p.path, cmd: cmd, title: p.name, restoreCmd: cmd == "claude" ? "claude -c" : cmd,
                                     lastActivity: Date()))
        query = ""
        searchFocused = false
        rebuild()
    }

    private func toggleStar(_ p: Project) {
        var next = meta
        var saved = next.byPath[p.path] ?? ProjectMeta()
        saved.starred.toggle()
        next.byPath[p.path] = saved
        Projects.saveMeta(next)
        rebuild()
    }

    /// The menu's "move to …": to another section, out of its folder; to its own, left where it is.
    private func move(_ p: Project, to section: ProjectSection) {
        let current = sectioned.first { $0.1.contains { $0.path == p.path } }?.0
        commitDrop(p.path, into: section,
                   folder: current == section ? tree.folder(of: p.path, in: section) : nil, snapshotOrder: nil)
    }

    /// Ends whatever drag is in flight by persisting the live order the user can
    /// already see. Every drop target funnels here, so releasing anywhere in the
    /// sidebar sticks instead of snapping back on the next rebuild. A folder isn't
    /// moved live (it would carry its rows across the pointer); it goes to the spot
    /// marked while hovering, if there was one.
    private func endDrag() {
        hoverSection = nil
        let spot = folderSpot
        folderSpot = nil
        switch drag {
        case .project(let path):
            if let section = sectioned.first(where: { $0.1.contains { $0.path == path } })?.0 {
                commitDrop(path, into: section, folder: tree.folder(of: path, in: section),
                           snapshotOrder: projects(in: section).map(\.path))
            } else {
                drag = nil
            }
        case .folder(let id):
            drag = nil
            if let spot, tree.canMove(id, to: spot) { saveTree { $0.move(id, to: spot) } }
        default:
            drag = nil
        }
    }

    /// Hovering a section header parks the row at the top of that section's loose
    /// rows, so a header drop lands where it looks like it will instead of by recency.
    private func liveMove(_ path: String, into section: ProjectSection) {
        liveMove(path, to: section) { $0.place(path, atTopOf: section, order: &$1) }
    }

    /// Hovering a row takes its place: same folder (or loose), right beside it.
    private func liveMove(_ path: String, before targetPath: String, in section: ProjectSection) {
        liveMove(path, to: section) { $0.place(path, nextTo: targetPath, in: section, order: &$1) }
    }

    /// Hovering a folder's name files the row at the top of that folder.
    private func liveMove(_ path: String, intoFolder id: String) {
        guard let section = tree.folder(id)?.section else { return }
        liveMove(path, to: section) { $0.place(path, atTopOf: id, order: &$1) }
    }

    /// Moves a dragged project in what's drawn — `sectioned` and the live `tree` — leaving
    /// the saving to endDrag. Only writes state that actually changed.
    private func liveMove(_ path: String, to section: ProjectSection,
                          _ change: (inout FolderTree, inout [String]) -> Void) {
        guard let p = projects.first(where: { $0.path == path }),
              let to = sectioned.firstIndex(where: { $0.0 == section }) else { return }
        for i in sectioned.indices where i != to && sectioned[i].1.contains(where: { $0.path == path }) {
            sectioned[i].1.removeAll { $0.path == path }
        }
        var order = sectioned[to].1.map(\.path)
        var next = tree
        change(&next, &order)
        if next != tree { tree = next }
        var byPath = Dictionary(sectioned[to].1.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        byPath[path] = p
        let rows = order.compactMap { byPath[$0] }
        if rows.map(\.path) != sectioned[to].1.map(\.path) { sectioned[to].1 = rows }
    }

    private func commitDrop(_ path: String, into target: ProjectSection, folder: String?, snapshotOrder: [String]?) {
        guard let p = projects.first(where: { $0.path == path }) else {
            drag = nil
            hoverSection = nil
            rebuild()
            return
        }
        var next = meta
        var saved = next.byPath[path] ?? ProjectMeta()
        if target == .starred {
            saved.starred = true
        } else {
            saved.starred = false
            saved.override = target == Projects.autoSection(p) ? nil : target
        }
        next.byPath[path] = saved
        var t = next.tree ?? FolderTree()
        t.file(path, into: folder)
        next.tree = t
        for section in ProjectSection.allCases {
            let key = section.rawValue
            next.order[key]?.removeAll { $0 == path }
            if next.order[key]?.isEmpty == true { next.order.removeValue(forKey: key) }
        }
        if let snapshotOrder { next.order[target.rawValue] = snapshotOrder }
        Projects.saveMeta(next)
        drag = nil
        hoverSection = nil
        rebuild()
    }
}

private struct ProjectRow: View {
    let project: Project
    let starred: Bool
    var indent: CGFloat = 0     // a step per folder it's inside
    var folder: String? = nil   // the sidebar folder it's filed in, by name
    var expanded = false        // its recent chats are listed under it
    var toggleExpand: (() -> Void)? = nil   // nil: no disclosure
    let open: () -> Void
    let openChat: (String) -> Void   // a tab in the project running this claude command
    let toggleStar: () -> Void
    let move: (ProjectSection) -> Void
    let rename: () -> Void
    let unfile: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(Emoji.forPath(project.path)).font(.system(size: 12))
            Text(project.name).font(ui(11)).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button(action: toggleStar) {
                    Text(starred ? "★" : "☆").font(ui(11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Last, so the star appearing on hover never shifts it. A button of its own: the
            // click stays here and doesn't reach the row's tap (which opens a new chat).
            if let toggleExpand, hovering || expanded {
                Button(action: toggleExpand) {
                    Text(expanded ? "▾" : "▸").font(ui(11)).foregroundStyle(.secondary)
                        .frame(width: 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "hide recent chats" : "show recent chats")
            }
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            ProjectChatsMenu(path: project.path, newChat: open, openChat: openChat)
            Divider()
            Button(starred ? "unstar" : "star", action: toggleStar)
            Button("rename…", action: rename)
            if let folder { Button("take out of “\(folder)”", action: unfile) }
            Divider()
            Button("move to active") { move(.active) }
            Button("move to dormant") { move(.dormant) }
            Button("move to archived") { move(.archived) }
            Divider()
            Self.links(project, local: true)
        }
        .help(project.path)
    }

    /// Its folder in Finder, its repo's web page (from the git remote; for another Mac's
    /// project, the manifest's).
    @ViewBuilder
    static func links(_ p: Project, local: Bool) -> some View {
        if local {
            Button("Open Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
        }
        let remote = local ? Manifest.remote(of: p.path) : Manifest.merged.first { $0.path == p.path }?.remote
        if let url = remote.flatMap(ProjectRef.webURL(forRemote:)) {
            Button("Open Repo Page (\(url.host ?? "web"))") { NSWorkspace.shared.open(url) }
        } else {
            Button("No Git Remote") {}.disabled(true)
        }
    }
}

/// A project's chats at the top of its right-click menu. Its own view because SwiftUI runs a
/// .contextMenu builder on every render of the row (the sidebar re-renders on a 10 s timer and on
/// hover), but a view's body inside the menu only when the menu is built, once per right-click —
/// so the folder listing and title reads happen then, not per row per render.
private struct ProjectChatsMenu: View {
    let path: String
    let newChat: () -> Void
    let openChat: (String) -> Void

    var body: some View {
        let chats = RecentChats.list(cwd: path)
        // a chat already open in a tab is taken to, not opened twice: two tabs on one session talk over each other
        Button("continue last chat") {
            if let last = chats.first, let tab = AppModel.shared.tab(session: last.id) { AppModel.shared.reveal(tab) }
            else { openChat("claude -c") }
        }
        .disabled(chats.isEmpty)
        Menu("resume chat") {
            if chats.isEmpty { Button("none yet") {}.disabled(true) }
            ForEach(chats) { c in
                let label = (c.title.count > 60 ? String(c.title.prefix(59)) + "…" : c.title) + "   " + RecentChats.age(c.modified)
                Toggle(label, isOn: Binding(get: { AppModel.shared.tab(session: c.id) != nil }, set: { _ in
                    Self.resume(c.id, open: openChat)
                }))
            }
        }
        Button("new chat", action: newChat)
    }

    /// To the tab that has this chat, else a new tab resuming it (`open` gets the command).
    static func resume(_ id: String, open: (String) -> Void) {
        if let tab = AppModel.shared.tab(session: id) { AppModel.shared.reveal(tab) }
        else { open("claude --resume \(id)") }
    }
}

/// One of an expanded project's recent chats, under its row: title, ✓ when a tab has it, age.
private struct ChatRow: View {
    let chat: RecentChat
    let isOpen: Bool
    let indent: CGFloat
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(chat.title).font(ui(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if isOpen { Text("✓").font(ui(9)).foregroundStyle(.secondary) }
            Text(RecentChats.age(chat.modified)).font(ui(9)).foregroundStyle(.tertiary)
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: resume)
        .contextMenu {
            Button("open", action: resume)
            Button("copy session id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.id, forType: .string)
            }
        }
        .help(chat.title)
    }
}

/// What the sidebar is currently dragging. One value rather than two parallel
/// optionals, so a tab dragged onto a project row (or the reverse) can't be
/// mistaken for a drag of the target's own kind — both payloads are plain text.
enum SidebarDrag: Equatable {
    case tab(Int)
    case project(String)
    case folder(String)   // a sidebar folder's id
}

/// The folder-name alert: a new folder (in a section, or inside another folder) or a rename.
private enum FolderNaming {
    case new(ProjectSection, parent: String?)
    case rename(SidebarFolder)

    var title: String {
        switch self {
        case .new: "new folder"
        case .rename: "rename folder"
        }
    }
}

/// Job request box: routed to a project and run in a job tab (same path as the phone).
struct JobBox: View {
    @State private var request = ""

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 6)
        TextField("ask — routed to a project, run in a job tab", text: $request, axis: .vertical)
            .textFieldStyle(.plain).font(ui(11)).lineLimit(1...4)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .onSubmit {
                let t = request.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { AppModel.shared.dispatchJob(t) }
                request = ""
            }
    }
}

/// Live-reorders sidebar tabs: dragging a row over another swaps them as you go.
private struct TabReorderDrop: DropDelegate {
    let targetId: Int
    @Binding var drag: SidebarDrag?
    let controller: KnifeWindowController
    /// Drags only reorder within the group shown on screen: status isn't something you
    /// can drop a tab into, and a cross-group move reshuffled the list mid-drag.
    let sameGroup: (Int, Int) -> Bool
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .tab(let from) = drag, from != targetId else { return }
        DispatchQueue.main.async {
            guard sameGroup(from, targetId) else { return }
            controller.moveTab(from, before: targetId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Also accepts project drags: releasing over the tab list must commit
        // them rather than leave the row visually moved but unsaved.
        DispatchQueue.main.async { end() }
        return true
    }
}

private struct ProjectRowDrop: DropDelegate {
    let targetPath: String
    let targetSection: ProjectSection
    @Binding var drag: SidebarDrag?
    let liveMove: (String, String, ProjectSection) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .project(let from) = drag, from != targetPath else { return }
        DispatchQueue.main.async { liveMove(from, targetPath, targetSection) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
    }
}

/// Rows that take no drop of their own (a project's chats): releasing over them still commits
/// whatever drag is on, and the cursor reads "move" as it does over the rows around them.
private struct EndDragDrop: DropDelegate {
    @Binding var drag: SidebarDrag?
    let end: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
    }
}

private struct ProjectSectionDrop: DropDelegate {
    let target: ProjectSection
    @Binding var drag: SidebarDrag?
    @Binding var hoverSection: ProjectSection?
    @Binding var folderSpot: FolderSpot?
    let canMove: (String, FolderSpot) -> Bool
    let liveMove: (String, ProjectSection) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        switch drag {
        case .project(let from):
            DispatchQueue.main.async {
                hoverSection = target
                liveMove(from, target)
            }
        case .folder(let id):
            // to the section's top level — its own section only
            guard canMove(id, .top(target)) else { return }
            DispatchQueue.main.async {
                hoverSection = target
                folderSpot = .top(target)
            }
        default:
            return
        }
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.async {
            if hoverSection == target { hoverSection = nil }
            if folderSpot == .top(target) { folderSpot = nil }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
    }
}

/// A sidebar folder's name. A project held over it files into it as you go, like the rows. A
/// folder held over it only marks where it would land — above, inside, or below when it's
/// closed — and moves on release: moved live, it would carry its rows across the pointer.
private struct FolderDrop: DropDelegate {
    let folder: SidebarFolder
    let open: Bool
    @Binding var drag: SidebarDrag?
    @Binding var spot: FolderSpot?
    let canMove: (String, FolderSpot) -> Bool
    let fileInto: (String, String) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard case .project(let path) = drag else { return }
        DispatchQueue.main.async {
            spot = .into(folder.id)
            fileInto(path, folder.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if case .folder(let id) = drag {
            let want = FolderSpot.over(folder.id, at: Double(info.location.y / SidebarView.folderRowHeight), open: open)
            let next = canMove(id, want) ? want : nil
            if next != spot { DispatchQueue.main.async { spot = next } }
        }
        return DropProposal(operation: drag == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        let mine: [FolderSpot] = [.before(folder.id), .into(folder.id), .after(folder.id)]
        DispatchQueue.main.async { if let s = spot, mine.contains(s) { spot = nil } }
    }

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { end() }
        return true
    }
}

// ─── Footer: spans the full window width, below sidebar + terminal ───
// Bordered square buttons in groups — view · panels · find · context · setup; a toggle that's
// on draws inverted. Tooltips carry the keyboard shortcut.

struct FooterBar: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject var theme = AppModel.shared.theme
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("gitPanel") private var gitPanel = false
    @AppStorage("chatView") private var chatView = false
    @AppStorage("autoClaude") private var autoClaude = true   // see KnifeWindowController.autoClaude
    @State private var hooksOn = HooksInstaller.installed()
    @State private var ctxScope: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            HStack(spacing: 8) {
                HStack(spacing: -1) { // segmented: shared borders
                    btn("terminal", on: !chatView && !controller.showBoard, help: "terminal view  ⌘⌥C") { controller.showBoard = false; chatView = false }
                    btn("chat", on: chatView && !controller.showBoard, help: "chat view  ⌘⌥C") { controller.showBoard = false; chatView = true }
                    btn("board", on: controller.showBoard, help: "session board  ⌘⇧B") { controller.showBoard = true }
                }
                sep
                btn("sidebar", on: !sidebarCollapsed, help: "sidebar  ⌘B") { sidebarCollapsed.toggle() }
                btn("git", on: gitPanel, help: "git panel  ⌘⌥B") { gitPanel.toggle() }
                sep
                btn("find", help: "find in this tab  ⌘F · next ⌘G") {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    (NSApp.delegate as? AppDelegate)?.find(item)
                }
                sep
                btn("global ctx", on: ctxScope == "global", help: "context shared by every session") {
                    ctxScope = ctxScope == "global" ? nil : "global"
                }
                .popover(isPresented: Binding(get: { ctxScope == "global" }, set: { if !$0 { ctxScope = nil } })) {
                    ContextPanel(scope: "global", cwd: nil)
                }
                btn("tab ctx", on: ctxScope == "session", help: "context for this tab's session") {
                    ctxScope = ctxScope == "session" ? nil : "session"
                }
                .popover(isPresented: Binding(get: { ctxScope == "session" }, set: { if !$0 { ctxScope = nil } })) {
                    ContextPanel(scope: "session", cwd: controller.activeTab?.currentCwd)
                }
                sep
                btn("theme: " + theme.mode.rawValue, help: "cycle auto · light · dark") { theme.cycle() }
                btn(autoClaude ? "claude on" : "claude off", on: autoClaude,
                    help: autoClaude ? "new tabs start Claude Code — ⌥⌘T or shift-click “new tab” for a plain shell"
                                     : "new tabs open a plain shell — click to start Claude Code in them") { autoClaude.toggle() }
                btn(hooksOn ? "alerts on" : "alerts off", on: hooksOn, help: "Claude Code hooks for working/attention alerts") {
                    _ = HooksInstaller.install(); hooksOn = HooksInstaller.installed()
                }
                btn("set default", help: "make Knife the default terminal") { DefaultTerminal.register() }
                Spacer(minLength: 8)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(ui(9)).foregroundStyle(.tertiary).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) === controller.window else { return }
            hooksOn = HooksInstaller.installed()
        }
    }

    private var sep: some View { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14) }

    private func btn(_ label: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label) }
            .buttonStyle(FootButtonStyle(on: on, paper: Color(nsColor: theme.nsColor(theme.current.background))))
            .help(help)
    }
}

/// Square, 1px-bordered, chrome type; hover tints, press darkens, `on` inverts (ink fill, paper text).
/// `wrap` lets a long label (the chat's question options) wrap instead of staying one line.
struct FootButtonStyle: ButtonStyle {
    var on = false
    let paper: Color
    var wrap = false

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, on: on, paper: paper, wrap: wrap) }

    private struct Face: View {
        let configuration: Configuration
        let on: Bool
        let paper: Color
        let wrap: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(ui(10)).lineLimit(wrap ? nil : 1).fixedSize(horizontal: !wrap, vertical: true)
                .foregroundStyle(on ? paper : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(on ? Color.primary.opacity(configuration.isPressed ? 0.7 : 0.9)
                               : Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.07 : 0))
                .overlay(Rectangle().stroke(Color.primary.opacity(on ? 0.9 : 0.35), lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

struct TabRow: View {
    @ObservedObject var tab: TabModel
    let active: Bool
    let activate: () -> Void
    let close: () -> Void
    let rename: () -> Void
    @ObservedObject var theme = AppModel.shared.theme
    @State private var hovering = false
    @State private var pulse = false

    private var accent: Color { theme.accentColor }
    private var signalOrange: Color { theme.attentionColor }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tab.attention ? signalOrange : (tab.working ? accent : .clear))
                .frame(width: 6, height: 6)
                .opacity(isPulsing && pulse ? 0.25 : 1.0)
                .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = isPulsing }
                .onChange(of: isPulsing) { _, now in pulse = now }
            Text(tab.emoji).font(.system(size: 12))
            label.font(ui(11, bold: active)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            if hovering {
                Button(action: close) {
                    Text("×").font(ui(11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if let word = statusWord {
                Text(word)
                    .font(ui(9))
                    .foregroundStyle(tab.status == .needsInput ? signalOrange : Color.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(active ? Color.primary.opacity(0.16) : Color.clear)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // The second click of a double-click renames; the first already activated, which is harmless.
            if (NSApp.currentEvent?.clickCount ?? 1) > 1 { rename() } else { activate() }
        }
        .onHover { hovering = $0 }
        .help(tab.displayTitle)
    }

    /// "name | context", one Text so the tail truncates the context and never the name.
    private var label: Text {
        guard let c = tab.context else { return Text(tab.title) }
        return Text(tab.title) + Text(" | " + c).font(ui(11))
            .foregroundColor(active ? Color.secondary : Color.secondary.opacity(0.6))
    }

    private var isPulsing: Bool { tab.working && !tab.attention }

    private var statusWord: String? {
        switch tab.status {
        case .idle: nil
        case .working: "working…"
        case .ready: "ready"
        case .needsInput: "needs input"
        }
    }
}

struct ContextPanel: View {
    let scope: String
    let cwd: String?

    var body: some View {
        let home = NSHomeDirectory()
        let result = scope == "global" ? (cwd: nil as String?, files: ContextFiles.global()) : ContextFiles.session(cwd: cwd)
        let short = { (p: String) -> String in p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        return VStack(alignment: .leading, spacing: 6) {
            Text(scope == "global" ? "loaded into every session"
                 : "loaded by this tab" + (result.cwd.map { " — " + short($0) } ?? ""))
                .font(ui(10, bold: true))
            if result.files.isEmpty {
                Text(scope == "global" ? "no global context files"
                     : (cwd != nil ? "no project context files" : "no shell running in this tab"))
                    .font(ui(10)).foregroundStyle(.secondary)
            }
            ForEach(result.files) { f in
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }) {
                    HStack(spacing: 8) {
                        Text((f.path as NSString).lastPathComponent).font(ui(10, bold: true))
                        Text(short((f.path as NSString).deletingLastPathComponent)).font(ui(9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(f.size < 1024 ? "\(f.size)b" : String(format: "%.1fk", Double(f.size) / 1024))
                            .font(ui(9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 300, alignment: .leading)
    }
}
