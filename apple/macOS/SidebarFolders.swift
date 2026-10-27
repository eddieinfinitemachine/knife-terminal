import Foundation

// ─── Sidebar folders: groups inside a project section that exist only in the sidebar ───
// No UI here: the tree, filing projects into it, and what a section draws. The sidebar drives it
// and the folder tests compile this file as is.

/// A folder made in the sidebar. Nothing on disk corresponds to it: renaming or deleting it only
/// changes the sidebar.
struct SidebarFolder: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    /// Fixed at creation. Folders reorder and nest within their section, never across: the
    /// projects inside one are in that section because of their status, not because of the folder.
    var section: ProjectSection
    var parent: String? = nil   // the folder it's in; nil = the section's top level
}

/// Where a dragged folder lands.
enum FolderSpot: Equatable {
    case top(ProjectSection)   // first at the section's top level (dropped on the section's name)
    case before(String)        // beside another folder, in that folder's list
    case after(String)
    case into(String)          // first inside another folder
}

extension FolderSpot {
    /// A folder held over another folder's name, `fraction` of the way down it: the top quarter
    /// puts it above, the bottom quarter below — only while the target is closed, since below an
    /// open folder's name reads as its first child — and anywhere else inside.
    static func over(_ target: String, at fraction: Double, open: Bool) -> FolderSpot {
        if fraction < 0.25 { return .before(target) }
        if fraction > 0.75 && !open { return .after(target) }
        return .into(target)
    }
}

/// One line of a section, top to bottom.
enum SidebarLine: Equatable, Identifiable {
    case folder(SidebarFolder, depth: Int, count: Int)   // count: projects anywhere inside it
    case project(String, depth: Int)

    var id: String {
        switch self {
        case .folder(let f, _, _): "folder:" + f.id
        case .project(let path, _): path
        }
    }
}

struct FolderTree: Codable, Equatable {
    /// Every folder. Siblings are drawn in the order they appear here.
    var folders: [SidebarFolder] = []
    /// project path → the folder it's filed in
    var place: [String: String] = [:]

    var isEmpty: Bool { folders.isEmpty && place.isEmpty }

    func folder(_ id: String) -> SidebarFolder? { folders.first { $0.id == id } }

    func children(of parent: String?, in section: ProjectSection) -> [SidebarFolder] {
        folders.filter { $0.section == section && $0.parent == parent }
    }

    /// `id` is `ancestor` or somewhere inside it. The walk is bounded, so a hand-edited file with
    /// a loop in it can't hang the sidebar.
    func isInside(_ id: String, _ ancestor: String) -> Bool {
        var cur: String? = id
        for _ in 0...folders.count {
            guard let c = cur else { return false }
            if c == ancestor { return true }
            cur = folder(c)?.parent
        }
        return false
    }

    /// The folder a project is drawn in. A project filed in a folder of another section — its
    /// status has moved it since — shows loose where it is now, and goes back in if it returns.
    func folder(of path: String, in section: ProjectSection) -> String? {
        guard let id = place[path], folder(id)?.section == section else { return nil }
        return id
    }

    /// "new folder" twice in one list gives "new folder 2".
    func freeName(_ want: String, in section: ProjectSection, parent: String?, except: String? = nil) -> String {
        let taken = Set(children(of: parent, in: section).filter { $0.id != except }.map(\.name))
        var name = want, n = 2
        while taken.contains(name) { name = "\(want) \(n)"; n += 1 }
        return name
    }

    // ─── Folders ───

    /// A new folder goes at the top of its list. Returns its id.
    @discardableResult
    mutating func add(_ name: String, in section: ProjectSection, parent: String? = nil,
                      id: String = UUID().uuidString) -> String {
        let parent = parent.flatMap { folder($0)?.section == section ? $0 : nil }
        let f = SidebarFolder(id: id, name: freeName(name, in: section, parent: parent), section: section, parent: parent)
        let first = folders.firstIndex { $0.section == section && $0.parent == parent }
        folders.insert(f, at: first ?? folders.count)
        return id
    }

    mutating func rename(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let want = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return }
        folders[i].name = freeName(want, in: folders[i].section, parent: folders[i].parent, except: id)
    }

    /// What was inside — projects and folders — moves up a level, to where the folder was: loose
    /// in the section for a top-level folder, else into its parent.
    mutating func delete(_ id: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let gone = folders[i]
        let at = folders[..<i].filter { $0.parent != id }.count
        var kids = folders.filter { $0.parent == id }
        folders.removeAll { $0.id == id || $0.parent == id }
        for k in kids.indices {
            kids[k].parent = gone.parent
            kids[k].name = freeName(kids[k].name, in: gone.section, parent: gone.parent)
        }
        folders.insert(contentsOf: kids, at: at)
        for (path, f) in place where f == id { place[path] = gone.parent }
    }

    func canMove(_ id: String, to spot: FolderSpot) -> Bool {
        guard let f = folder(id) else { return false }
        switch spot {
        case .top(let section):
            return section == f.section
        case .before(let t), .after(let t), .into(let t):
            // not beside or into itself, nor into anything inside it
            guard let target = folder(t), target.section == f.section else { return false }
            return !isInside(t, id)
        }
    }

    @discardableResult
    mutating func move(_ id: String, to spot: FolderSpot) -> Bool {
        guard canMove(id, to: spot), var f = folder(id) else { return false }
        folders.removeAll { $0.id == id }
        let at: Int
        switch spot {
        case .top(let section):
            f.parent = nil
            at = folders.firstIndex { $0.section == section && $0.parent == nil } ?? folders.count
        case .before(let t):
            f.parent = folder(t)?.parent
            at = folders.firstIndex { $0.id == t } ?? folders.count
        case .after(let t):
            f.parent = folder(t)?.parent
            at = folders.firstIndex { $0.id == t }.map { $0 + 1 } ?? folders.count
        case .into(let t):
            f.parent = t
            at = folders.firstIndex { $0.parent == t } ?? folders.count
        }
        f.name = freeName(f.name, in: f.section, parent: f.parent)
        folders.insert(f, at: at)
        return true
    }

    // ─── Projects ───

    mutating func file(_ path: String, into folder: String?) {
        if let folder, self.folder(folder) != nil { place[path] = folder } else { place.removeValue(forKey: path) }
    }

    /// A dragged project held over another row: it joins that row's list (its folder, or loose)
    /// right beside it — after it when coming from above on screen, before it otherwise — so the
    /// two swap and the pointer ends up over the dragged row rather than a third one. `order` is
    /// the section's order; `path` may be arriving from another section and not be in it yet.
    mutating func place(_ path: String, nextTo target: String, in section: ProjectSection, order: inout [String]) {
        guard path != target else { return }
        let drawn = drawOrder(in: section, paths: order)
        let after = drawn.firstIndex(of: path).flatMap { from in drawn.firstIndex(of: target).map { from < $0 } } ?? false
        file(path, into: folder(of: target, in: section))
        order.removeAll { $0 == path }
        guard let t = order.firstIndex(of: target) else { order.insert(path, at: 0); return }
        order.insert(path, at: after ? t + 1 : t)
    }

    /// A dragged project held over a folder's name: first inside that folder.
    mutating func place(_ path: String, atTopOf id: String, order: inout [String]) {
        guard let f = folder(id) else { return }
        file(path, into: id)
        order.removeAll { $0 == path }
        let first = order.firstIndex { folder(of: $0, in: f.section) == id }
        order.insert(path, at: first ?? 0)
    }

    /// A dragged project held over a section's name: out of any folder, first among the loose rows.
    mutating func place(_ path: String, atTopOf section: ProjectSection, order: inout [String]) {
        file(path, into: nil)
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
    }

    // ─── Drawing ───

    /// What a section draws: its folders, each followed by what's in it (folders, then projects)
    /// unless collapsed, then its loose projects. `paths` is the section's projects in order.
    func lines(in section: ProjectSection, paths: [String], collapsed: (String) -> Bool = { _ in false }) -> [SidebarLine] {
        var direct: [String?: [String]] = [:]
        for p in paths { direct[folder(of: p, in: section), default: []].append(p) }
        var out: [SidebarLine] = []
        func count(_ id: String) -> Int {
            (direct[id]?.count ?? 0) + children(of: id, in: section).reduce(0) { $0 + count($1.id) }
        }
        // only reachable from the top, so a loop in a hand-edited file is never walked
        func walk(_ parent: String?, depth: Int) {
            for f in children(of: parent, in: section) {
                out.append(.folder(f, depth: depth, count: count(f.id)))
                guard !collapsed(f.id) else { continue }
                walk(f.id, depth: depth + 1)
                out += (direct[f.id] ?? []).map { .project($0, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        out += (direct[nil] ?? []).map { .project($0, depth: 0) }
        return out
    }

    /// The section's projects in the order they're drawn with everything open.
    func drawOrder(in section: ProjectSection, paths: [String]) -> [String] {
        lines(in: section, paths: paths).compactMap { line -> String? in
            guard case .project(let p, _) = line else { return nil }
            return p
        }
    }

    /// Before saving: forget projects that are no longer listed and filings into folders that are
    /// gone, and lift a folder whose parent is missing (or loops back to it) to the top level.
    mutating func prune(keeping paths: Set<String>) {
        let ids = Set(folders.map(\.id))
        place = place.filter { paths.contains($0.key) && ids.contains($0.value) }
        for i in folders.indices {
            guard let p = folders[i].parent else { continue }
            if folder(p)?.section != folders[i].section || isInside(p, folders[i].id) { folders[i].parent = nil }
        }
    }
}
