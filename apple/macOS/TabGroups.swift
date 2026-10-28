import Foundation

// The sidebar's tab list, grouped by repo: which group a tab is in, the order groups are drawn in,
// and what a row's label still needs to say under its group's header.
// Foundation only (plus Prompts.swift's Repos), so a plain swiftc script can compile it to test it.

/// The group a tab is listed under: its repo (clones and worktrees of one repo share it), else
/// the folder it's in, else "shell" for a tab with no directory at all.
struct TabGroupID: Hashable {
    let key: String    // RepoKey.key, "dir:" + the folder's path, or "shell"; saved in the folded set
    let name: String   // the header

    static let shell = TabGroupID(key: "shell", name: "shell")

    static func of(cwd: String?, repo: RepoKey?, home: String = NSHomeDirectory()) -> TabGroupID {
        if let repo { return TabGroupID(key: repo.key, name: repo.name) }
        guard let cwd, !cwd.isEmpty else { return .shell }
        let path = (cwd as NSString).standardizingPath
        let name = path == (home as NSString).standardizingPath ? "~" : (path as NSString).lastPathComponent
        return TabGroupID(key: "dir:" + path, name: name)
    }

    /// Reads git config (mtime-cached in Repos); callers keep the answer per cwd.
    static func of(cwd: String?) -> TabGroupID {
        of(cwd: cwd, repo: cwd.flatMap(Repos.key(for:)))
    }
}

/// How much a tab wants you, most first. A group ranks, and a folded header shows, its most urgent tab's.
enum TabUrgency: Int, Comparable {
    case needsInput, working, none

    /// `attention` is the row's orange dot (needs input, or finished while you were elsewhere).
    static func of(attention: Bool, needsInput: Bool, working: Bool) -> TabUrgency {
        attention || needsInput ? .needsInput : working ? .working : .none
    }

    static func < (a: TabUrgency, b: TabUrgency) -> Bool { a.rawValue < b.rawValue }
}

/// One tab as the grouping sees it, taken from `tabs` in manual order.
struct TabGroupMember {
    let id: Int
    let group: TabGroupID
    let urgency: TabUrgency
    let lastActivity: Date?
}

/// One group as drawn: its tabs in manual order, and the most urgent status among them.
struct TabSection: Equatable {
    let group: TabGroupID
    var ids: [Int]
    var urgency: TabUrgency
}

/// The groups as they stood when the pointer came onto the tab list. Membership and group order
/// hold still under it; the order inside a group stays live, so a drag can reorder it.
struct TabGroupFreeze: Equatable {
    let membership: [Int: TabGroupID]
    let order: [String]

    init(_ sections: [TabSection]) {
        var m: [Int: TabGroupID] = [:]
        for s in sections { for id in s.ids { m[id] = s.group } }
        membership = m
        order = sections.map(\.group.key)
    }
}

enum TabGroups {
    /// Groups in display order: any tab needing input first, then any working, then the rest;
    /// within each, the most recent activity first (ties keep the manual order of their first tab).
    /// Frozen: each tab stays in the group it was in, and those groups keep their order; a group
    /// that only appeared since (a new tab in a new repo) goes after them, ranked the live way.
    static func sections(_ members: [TabGroupMember], frozen: TabGroupFreeze? = nil) -> [TabSection] {
        var byKey: [String: TabSection] = [:]
        var latest: [String: Date] = [:]   // a group's most recent activity: the max over its tabs
        var firstSeen: [String] = []
        for m in members {
            let g = frozen?.membership[m.id] ?? m.group
            if var s = byKey[g.key] {
                s.ids.append(m.id)
                s.urgency = min(s.urgency, m.urgency)
                byKey[g.key] = s
            } else {
                byKey[g.key] = TabSection(group: g, ids: [m.id], urgency: m.urgency)
                firstSeen.append(g.key)
            }
            if let t = m.lastActivity { latest[g.key] = max(latest[g.key] ?? t, t) }
        }
        let ranked = firstSeen.enumerated().sorted { a, b in
            let ua = byKey[a.element]!.urgency, ub = byKey[b.element]!.urgency
            if ua != ub { return ua < ub }
            let ta = latest[a.element] ?? .distantPast, tb = latest[b.element] ?? .distantPast
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map(\.element)
        guard let frozen else { return ranked.map { byKey[$0]! } }
        let held = frozen.order.filter { byKey[$0] != nil }
        let heldSet = Set(held)
        return (held + ranked.filter { !heldSet.contains($0) }).map { byKey[$0]! }
    }

    /// What a row says under its group's header. A tab named after its group (a project tab)
    /// drops the name the header already shows: just Claude's chat title, or the name when there
    /// is none. A tab with a name of its own (renamed) keeps "name | context".
    static func label(title: String, context: String?, groupName: String) -> (name: String, context: String?) {
        guard title.caseInsensitiveCompare(groupName) == .orderedSame else { return (title, context) }
        return (context ?? title, nil)
    }

    /// The folded groups, saved one key per line (a path can hold a comma).
    static func folded(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func toggledFold(_ key: String, in raw: String) -> String {
        var set = folded(raw)
        if !set.insert(key).inserted { set.remove(key) }
        return set.sorted().joined(separator: "\n")
    }
}
