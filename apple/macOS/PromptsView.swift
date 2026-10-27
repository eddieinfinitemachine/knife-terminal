import SwiftUI
import AppKit

/// Sidebar sections under "+ new tab": prompts saved for everywhere, prompts kept to the active
/// tab's repo (any clone or worktree of it), and the clipboard pile. A click puts the text where
/// you're typing in the active tab without sending it, so you can add to it first.
struct PromptSections: View {
    let controller: KnifeWindowController
    let repo: RepoKey?   // the active tab's; nil hides the repo section
    let first: Int       // the prompts label's number; the sections after it count on from there
    @ObservedObject private var store = AppModel.shared.prompts
    @ObservedObject private var pile = AppModel.shared.clips
    @AppStorage("knife.collapsedSections") private var collapsedRaw = ""
    @State private var editing: PromptDraft?
    /// The pile as it was when the pointer arrived over it: a used clip stays put (dimmed)
    /// until the pointer leaves, so the rows never slide under a click.
    @State private var frozenClips: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            let global = store.all.filter { $0.repo == nil }
            header("prompts", number: first, fold: "prompts", count: global.count) {
                addButton(help: "save a prompt") { editing = PromptDraft() }
            }
            if !isCollapsed("prompts") {
                promptRows(global, empty: "none yet — + saves one") { editing = PromptDraft() }
            }
            if let repo {
                let kept = store.all.filter { $0.repo == repo.key }
                header(repo.name, number: first + 1, fold: "prompts:repo", count: kept.count, help: "prompts kept to \(repo.key)") {
                    addButton(help: "save a prompt for \(repo.name)") { editing = PromptDraft(repo: repo) }
                }
                if !isCollapsed("prompts:repo") {
                    promptRows(kept, empty: "none yet — + saves one for this repo") { editing = PromptDraft(repo: repo) }
                }
            }
            clipboard
        }
        .preference(key: PromptSectionCount.self, value: shownCount)
        .sheet(item: $editing) { draft in
            PromptEditor(draft: draft, save: save, cancel: { editing = nil })
        }
    }

    // ─── Prompts ───

    @ViewBuilder
    private func promptRows(_ list: [SavedPrompt], empty: String, add: @escaping () -> Void) -> some View {
        if list.isEmpty {
            row(empty, dim: true, help: nil, action: add)
        }
        ForEach(list) { p in
            row(p.label, help: p.text) { controller.insertIntoActiveTab(p.text) }
                .contextMenu {
                    Button("paste into tab") { controller.insertIntoActiveTab(p.text) }
                    Button("copy") { Self.copy(p.text) }
                    Divider()
                    Button("edit…") { editing = PromptDraft(p) }
                    if p.repo != nil {
                        Button("show in every repo") { store.update(p.id) { $0.repo = nil; $0.repoName = nil } }
                    } else if let repo {
                        Button("keep to “\(repo.name)”") { store.update(p.id) { $0.repo = repo.key; $0.repoName = repo.name } }
                    }
                    Button("delete “\(Self.short(p.label))”") { store.delete(p.id) }
                }
        }
    }

    private func save(_ d: PromptDraft) {
        editing = nil
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = d.promptId {
            store.update(id) { $0.name = name.isEmpty ? nil : name; $0.text = d.text }
        } else {
            store.add(SavedPrompt(name: name.isEmpty ? nil : name, text: d.text, repo: d.repo, repoName: d.repoName))
        }
    }

    // ─── Clipboard pile: shown only while it holds something ───

    private var shownClips: [String] { frozenClips ?? pile.clips }

    /// Labels this view draws, so the sidebar numbers the one after them without a gap.
    private var shownCount: Int { 1 + (repo == nil ? 0 : 1) + (shownClips.isEmpty ? 0 : 1) }

    @ViewBuilder
    private var clipboard: some View {
        let shown = shownClips
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                header("clipboard", number: first + shownCount - 1, fold: "clipboard", count: shown.count) {
                    Button(action: pile.clear) { Text("clear").font(ui(11)) }
                        .buttonStyle(.plain).foregroundStyle(Color.inkFaint)
                        .help("empty the pile")
                }
                if !isCollapsed("clipboard") {
                    ForEach(shown, id: \.self) { clip in
                        let used = !pile.clips.contains(clip)
                        row(Pile.firstLine(clip), dim: used, help: used ? nil : clip) {
                            guard !used else { return }
                            pile.remove(clip) // off the pile as it's used
                            controller.insertIntoActiveTab(clip)
                        }
                        .contextMenu {
                            Button("copy") { Self.copy(clip) }
                            Button("remove") { pile.remove(clip) }
                        }
                    }
                }
            }
            .onHover { inside in frozenClips = inside ? pile.clips : nil }
        }
    }

    // ─── Pieces ───

    /// A numbered section label; click the title to fold.
    private func header<Trailing: View>(_ title: String, number: Int, fold: String, count: Int, help: String? = nil,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        SectionLabel(number: number, title: title, folded: isCollapsed(fold), count: count, trailing: trailing)
            .contentShape(Rectangle())
            .onTapGesture { toggleCollapse(fold) }
            .help(help ?? "")
    }

    private func addButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("+").font(ui(14)) }
            .buttonStyle(.plain).foregroundStyle(Color.ink)
            .help(help)
    }

    private func row(_ label: String, dim: Bool = false, help: String?, action: @escaping () -> Void) -> some View {
        Text(label).font(ui(12.5)).lineLimit(1).truncationMode(.tail)
            .foregroundStyle(dim ? Color.inkFaint : Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help.map { $0.count > 2000 ? String($0.prefix(2000)) + "…" : $0 } ?? "")
    }

    private func isCollapsed(_ key: String) -> Bool {
        collapsedRaw.split(separator: ",").contains(Substring(key))
    }

    private func toggleCollapse(_ key: String) {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if !set.insert(key).inserted { set.remove(key) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }
}

/// What the add/edit sheet works on: a new prompt (maybe for a repo) or an existing one.
struct PromptDraft: Identifiable {
    let id = UUID()
    var promptId: UUID?
    var name = ""
    var text = ""
    var repo: String?
    var repoName: String?

    init() {}
    init(repo: RepoKey) { self.repo = repo.key; repoName = repo.name }
    init(_ p: SavedPrompt) { promptId = p.id; name = p.name ?? ""; text = p.text; repo = p.repo; repoName = p.repoName }
}

/// A sheet rather than an alert: an alert's text field can't take more than one line.
private struct PromptEditor: View {
    @State var draft: PromptDraft
    let save: (PromptDraft) -> Void
    let cancel: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.promptId == nil ? "save a prompt" : "edit prompt").font(ui(13)).foregroundStyle(Color.ink)
            if let r = draft.repoName {
                Text("kept to “\(r)”").font(ui(10)).foregroundStyle(Color.inkSoft)
            }
            TextField("name (optional)", text: $draft.name)
                .textFieldStyle(.roundedBorder).font(ui(11))
            TextEditor(text: $draft.text)
                .font(ui(11))
                .focused($textFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 160)
                .overlay(Rectangle().stroke(Color.rule, lineWidth: 1))
            HStack {
                Text("⌘↩ saves").font(ui(10)).foregroundStyle(Color.inkFaint)
                Spacer()
                Button("cancel", action: cancel).keyboardShortcut(.cancelAction)
                // ⌘↩, not ↩: Return has to make a new line in the editor
                Button("save") { save(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { textFocused = true }
    }
}

/// How many numbered labels PromptSections drew (prompts, the repo's, the clipboard), so the
/// projects label after them takes the next number.
struct PromptSectionCount: PreferenceKey {
    static let defaultValue = 1   // views that don't set it report this too, so the largest wins
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}
