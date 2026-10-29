import Foundation

// The sidebar's tab list: active and dormant, with repo groups under each. Which group a tab is
// in, the order groups are drawn in, and what a row's label still needs to say under its header.
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

/// The top level of the tab list: tabs you're in the middle of, and the rest.
/// The rule is SidebarGroup's from before f77c5cc, with its needs input / working / ready
/// groups folded into active: a tab that's needing input, working or ready (straight from the
/// hooks) is active whatever its timestamp; otherwise it's active if anything touched it — a hook
/// event, typing, opening it — in the last 24 hours, and dormant after a day (or a shell nobody
/// has used). Time, not process scanning: it doesn't flicker while a scan catches up. Typing never
/// moves a tab out of active (it only ever refreshes the timestamp), so a busy tab can't flap.
enum TabTier: String, CaseIterable {
    case active, dormant

    static let activeWindow: TimeInterval = 24 * 60 * 60

    static func of(urgency: TabUrgency, ready: Bool, lastActivity: Date?, now: Date = Date()) -> TabTier {
        if urgency != .none || ready { return .active }
        if let t = lastActivity, now.timeIntervalSince(t) < activeWindow { return .active }
        return .dormant
    }

    /// Its own key in the folded set: repo groups are saved as "<tier>:<repo key>", never "tier:…".
    var foldKey: String { "tier:" + rawValue }
}

/// One tab as the grouping sees it, taken from `tabs` in manual order.
struct TabGroupMember {
    let id: Int
    let group: TabGroupID
    let urgency: TabUrgency
    let lastActivity: Date?
    let tier: TabTier
}

/// One repo group as drawn under its tier: its tabs in manual order, and the most urgent status
/// among them. A repo can have one under active and another under dormant.
struct TabSection: Equatable {
    let tier: TabTier
    let group: TabGroupID
    var ids: [Int]
    var urgency: TabUrgency

    /// Unique in the list, and the key it's folded under.
    var id: String { tier.rawValue + ":" + group.key }
}

/// active or dormant, with its repo groups in display order.
struct TabTierSection: Equatable {
    let tier: TabTier
    var repos: [TabSection]

    var count: Int { repos.reduce(0) { $0 + $1.ids.count } }
    var urgency: TabUrgency { repos.map(\.urgency).min() ?? .none }
}

/// The list as it stood when the pointer came onto it. Which tier and repo each tab is under,
/// and the order of repos within each tier, hold still; the order inside a repo group stays live,
/// so a drag can reorder it.
struct TabGroupFreeze: Equatable {
    struct Place: Equatable { let tier: TabTier; let group: TabGroupID }
    let membership: [Int: Place]
    let order: [String]   // TabSection ids

    init(_ tiers: [TabTierSection]) {
        var m: [Int: Place] = [:]
        for t in tiers { for s in t.repos { for id in s.ids { m[id] = Place(tier: s.tier, group: s.group) } } }
        membership = m
        order = tiers.flatMap(\.repos).map(\.id)
    }
}

enum TabGroups {
    /// active, then dormant (an empty one left out), each holding its repo groups: any tab needing
    /// input first, then any working, then the rest; within each, the most recent activity first
    /// (ties keep the manual order of their first tab). Under dormant only recency is left to
    /// rank by, since a tab needing input or working is active.
    /// Frozen: each tab stays where it was, and those groups keep their order; a group that only
    /// appeared since (a new tab in a new repo) goes after them in its tier, ranked the live way.
    static func tiers(_ members: [TabGroupMember], frozen: TabGroupFreeze? = nil) -> [TabTierSection] {
        var byId: [String: TabSection] = [:]
        var latest: [String: Date] = [:]   // a group's most recent activity: the max over its tabs
        var firstSeen: [String] = []
        for m in members {
            let place = frozen?.membership[m.id] ?? TabGroupFreeze.Place(tier: m.tier, group: m.group)
            let id = TabSection(tier: place.tier, group: place.group, ids: [], urgency: .none).id
            if var s = byId[id] {
                s.ids.append(m.id)
                s.urgency = min(s.urgency, m.urgency)
                byId[id] = s
            } else {
                byId[id] = TabSection(tier: place.tier, group: place.group, ids: [m.id], urgency: m.urgency)
                firstSeen.append(id)
            }
            if let t = m.lastActivity { latest[id] = max(latest[id] ?? t, t) }
        }
        let ranked = firstSeen.enumerated().sorted { a, b in
            let ua = byId[a.element]!.urgency, ub = byId[b.element]!.urgency
            if ua != ub { return ua < ub }
            let ta = latest[a.element] ?? .distantPast, tb = latest[b.element] ?? .distantPast
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map(\.element)
        let held = frozen?.order.filter { byId[$0] != nil } ?? []
        let heldSet = Set(held)
        let order = held + ranked.filter { !heldSet.contains($0) }
        return TabTier.allCases.compactMap { tier in
            let repos = order.compactMap { byId[$0] }.filter { $0.tier == tier }
            return repos.isEmpty ? nil : TabTierSection(tier: tier, repos: repos)
        }
    }

    /// The old plain-list rule: while nothing is active, the "dormant" header isn't drawn (nor
    /// its fold honored), so a window of idle shells reads as a plain list of repo groups.
    static func showsTierHeaders(_ tiers: [TabTierSection]) -> Bool {
        tiers.contains { $0.tier == .active }
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

    /// The folded set once the active tab has changed from `old` to `new`: whatever hides the new
    /// active tab opens — its repo group, and its tier if that header is drawn — so its row shows
    /// highlighted. Only on a change: a group folded over the active tab stays folded. Nothing
    /// else opens, so no other group moves.
    static func revealing(active new: Int?, previous old: Int?, in tiers: [TabTierSection], folded raw: String) -> String {
        guard let new, new != old,
              let section = tiers.flatMap(\.repos).first(where: { $0.ids.contains(new) }) else { return raw }
        var set = folded(raw)
        var changed = set.remove(section.id) != nil
        if showsTierHeaders(tiers), set.remove(section.tier.foldKey) != nil { changed = true }
        return changed ? set.sorted().joined(separator: "\n") : raw
    }

    static func toggledFold(_ key: String, in raw: String) -> String {
        var set = folded(raw)
        if !set.insert(key).inserted { set.remove(key) }
        return set.sorted().joined(separator: "\n")
    }
}
