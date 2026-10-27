import SwiftUI
import AppKit
import SwiftTerm
import KnifeKit

extension Notification.Name {
    static let knifeChatScrollTo = Notification.Name("knife.chatScrollTo") // object: window controller; userInfo["id"]: message id
}

// ─── The rail: jump back to something you said ───
// A tick down the right edge of a Claude tab for each prompt you've sent in its chat. Hover one for
// the prompt and the start of the answer; click it to bring the prompt back on screen (ported from
// the Electron app's rail).
//
// It floats over the terminal instead of taking a column from it. SwiftTerm already keeps a strip at
// its right edge for the scroller, so the 12 pt rail covers no text, and the terminal never reflows
// when a rail comes or goes. Only the ticks take the pointer: above and below them the scroller works.

/// A prompt you sent, and the last thing Claude said before your next one: its answer, not "let me look".
struct RailPrompt: Identifiable, Equatable, Sendable {
    let id: String     // the user message's id: the chat view scrolls to it
    let text: String
    var reply = ""

    static func list(_ msgs: [ChatMessage]) -> [RailPrompt] {
        var out: [RailPrompt] = []
        for m in msgs {
            switch m.kind {
            case .user where m.detail == nil: // not one still waiting in Claude's queue
                out.append(RailPrompt(id: m.id, text: m.text))
            case .assistant where !out.isEmpty && m.ask == nil:
                out[out.count - 1].reply = String(m.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(400))
            default: break
            }
        }
        return out
    }
}

@MainActor
final class PromptRails: ObservableObject {
    static let shared = PromptRails()

    struct Miss: Equatable { let tab: Int; let prompt: String; let text: String }

    @Published private(set) var lists: [Int: [RailPrompt]] = [:] // tab id → its prompts; none: no rail
    @Published private(set) var miss: Miss?                        // a jump that found nothing, said on the card
    private var pending: Set<Int> = []
    private var hunt = 0 // a newer click calls off the search an older one started

    /// A Claude Code hook fired in this tab (a prompt sent, a tool run, a turn done): its transcript
    /// has moved, so read it again shortly. A burst of hooks is one read, and a tab in the background
    /// is read when it's brought forward instead.
    func hookFired(_ tab: TabModel) {
        guard AppModel.shared.window(of: tab)?.activeTab === tab, pending.insert(tab.id).inserted else { return }
        let id = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak tab] in
            self?.pending.remove(id)
            if let tab { self?.refresh(tab) }
        }
    }

    /// The tab's prompts, while claude itself runs in it. Read through TranscriptReader's cache, which
    /// parses only what was appended since the chat view (or the last refresh) read it.
    func refresh(_ tab: TabModel) {
        let id = tab.id, pid = tab.shellPid
        let src = TranscriptReader.source(for: tab, cwd: tab.currentCwd)
        Task {
            let list = await Task.detached { () -> [RailPrompt] in
                guard pid > 0, TabModel.agentsByShell([pid])[pid] == "claude",
                      let chat = TranscriptReader.chat(src), !chat.codex else { return [] }
                return RailPrompt.list(chat.msgs)
            }.value
            for k in lists.keys where AppModel.shared.tab(k) == nil { lists[k] = nil } // closed tabs
            guard AppModel.shared.tab(id) != nil, lists[id] ?? [] != list else { return }
            lists[id] = list.isEmpty ? nil : list
        }
    }

    /// Bring prompt `i` back on screen. The chat view scrolls to it; the terminal finds it in its
    /// scrollback, or pages fullscreen Claude Code to it with its own keys.
    func jump(_ list: [RailPrompt], _ i: Int, in tab: TabModel, controller: KnifeWindowController) {
        guard list.indices.contains(i) else { return }
        hunt += 1
        miss = nil
        if controller.chatShowing && !controller.showBoard {
            NotificationCenter.default.post(name: .knifeChatScrollTo, object: controller, userInfo: ["id": list[i].id])
            return
        }
        let view = tab.view
        view.window?.makeFirstResponder(view)
        let t = view.getTerminal()
        let (snippet, want) = RailSearch.target(list.map(\.text), i, cols: t.cols)
        if t.isCurrentBufferAlternate {
            let me = hunt
            Task { await page(to: snippet, up: i >= list.count / 2, in: tab, controller: controller, me: me, prompt: list[i].id) }
            return
        }
        // Claude Code without fullscreen: the chat is in the terminal's own scrollback
        let top = t.buffer.totalLinesTrimmed
        var rows: [String] = []
        while let line = t.getScrollInvariantLine(row: top + rows.count) { rows.append(line.translateToString(trimRight: true)) }
        let input = max(0, rows.count - t.rows) + t.buffer.y // the cursor's row: the input box
        guard let y = RailSearch.row(in: rows, snippet: snippet, want: want, skip: input) else {
            return say("couldn’t find that prompt in this tab’s scrollback", tab.id, list[i].id)
        }
        view.scrollTo(row: max(0, y - 2))
        flash(view, row: y)
    }

    /// Fullscreen Claude Code draws the chat itself, and nothing outside can tell it where to scroll.
    /// So page through it the way you would, from the nearer end, until the prompt is on screen.
    /// Ctrl+Home/End and PgUp/PgDn are Claude Code's own keys for this.
    private func page(to snippet: String, up: Bool, in tab: TabModel, controller: KnifeWindowController, me: Int, prompt: String) async {
        let view = tab.view
        view.send(txt: up ? "\u{1b}[1;5F" : "\u{1b}[1;5H")
        await settle(view)
        var last = "", same = 0
        for _ in 0..<400 {
            guard me == hunt, controller.activeTab === tab else { return }
            let t = view.getTerminal()
            let rows = (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            if let y = RailSearch.screenRow(rows, snippet: snippet, skip: t.buffer.y) {
                return flash(view, row: t.getTopVisibleRow() + y)
            }
            let screen = rows.joined(separator: "\n")
            if screen == last { same += 1; if same >= 2 { break } } else { same = 0 } // reached the end without seeing it
            last = screen
            view.send(txt: up ? "\u{1b}[5~" : "\u{1b}[6~")
            await settle(view)
        }
        if me == hunt { say("couldn’t find that prompt on screen: it may be from before a /clear or /compact", tab.id, prompt) }
    }

    /// Wait for the program to finish redrawing: the screen unchanged for a beat, or give up waiting.
    private func settle(_ view: KnifeTermView) async {
        try? await Task.sleep(for: .milliseconds(90))
        var last = view.plainScreen()
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(60))
            let now = view.plainScreen()
            if now == last { return }
            last = now
        }
    }

    /// Light the row up for a moment, the way a find hit shows; left alone if you've selected since.
    private func flash(_ view: KnifeTermView, row: Int) {
        view.selection.select(row: row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak view] in
            guard let view, view.selection.active, view.selection.start.row == row, view.selection.end.row == row else { return }
            view.selectNone()
        }
    }

    private func say(_ text: String, _ tab: Int, _ prompt: String) {
        let m = Miss(tab: tab, prompt: prompt, text: text)
        miss = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.miss == m { self?.miss = nil }
        }
    }
}

struct PromptRail: View {
    @ObservedObject var controller: KnifeWindowController
    @ObservedObject private var rails = PromptRails.shared
    @State private var frozen: [RailPrompt]? // the list as it stood when the pointer came on: ticks hold still under it
    @State private var hovered: Int?
    @State private var shown: Int?           // the card up: the tick the pointer settled on
    @State private var here: String?         // the prompt last jumped to
    @State private var settling: Task<Void, Never>?

    static let width: CGFloat = 12
    private static let inset: (top: CGFloat, bottom: CGFloat) = (12, 12) // the header above keeps it clear of the titlebar

    var body: some View {
        let tab = controller.activeTab
        let list = frozen ?? tab.flatMap { rails.lists[$0.id] } ?? []
        GeometryReader { geo in
            if let tab, !list.isEmpty { ticks(list, tab, height: geo.size.height) }
        }
        .frame(width: list.isEmpty ? 0 : Self.width)
        .task(id: tab?.id) {
            frozen = nil; hovered = nil; shown = nil; here = nil
            if let tab { rails.refresh(tab) }
        }
        .onChange(of: hovered) {
            // the card waits for the pointer to rest, so sweeping down the rail doesn't flash every prompt
            settling?.cancel()
            guard let h = hovered else { shown = nil; return }
            let wait = shown == nil ? 300 : 100
            settling = Task {
                try? await Task.sleep(for: .milliseconds(wait))
                if !Task.isCancelled { shown = h }
            }
        }
    }

    @ViewBuilder
    private func ticks(_ list: [RailPrompt], _ tab: TabModel, height: CGFloat) -> some View {
        let avail = max(0, height - Self.inset.top - Self.inset.bottom)
        let h = min(10, max(2, (avail / CGFloat(list.count)).rounded(.down)))
        let first = max(0, list.count - Int(avail / h)) // more than fit: the latest ones
        let n = list.count - first
        let top = Self.inset.top + (avail - CGFloat(n) * h) / 2
        if n > 0 {
            let at = { (y: CGFloat) in first + min(n - 1, max(0, Int(y / h))) }
            VStack(spacing: 0) {
                ForEach(first..<list.count, id: \.self) { i in
                    let on = i == hovered || list[i].id == here
                    Rectangle().fill(on ? Color.ink : Color.inkFaint)
                        .frame(width: on ? 9 : 5, height: 1)
                        .padding(.trailing, 2)
                        .frame(width: Self.width, height: h, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    if frozen == nil { frozen = list }
                    hovered = at(p.y)
                case .ended:
                    hovered = nil
                    frozen = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                let i = at(v.location.y)
                here = list[i].id
                rails.jump(list, i, in: tab, controller: controller)
            })
            .overlay(alignment: .topTrailing) { card(list, first: first, h: h, top: top, height: height) }
            .padding(.top, top)
            .frame(width: Self.width, height: height, alignment: .top)
        }
    }

    /// The prompt under the pointer and the start of its answer, beside the tick, kept inside the pane.
    @ViewBuilder
    private func card(_ list: [RailPrompt], first: Int, h: CGFloat, top: CGFloat, height: CGFloat) -> some View {
        let miss = rails.miss.flatMap { $0.tab == controller.activeTab?.id ? $0 : nil }
        if let k = shown ?? miss.flatMap({ m in list.firstIndex { $0.id == m.prompt } }), k >= first, k < list.count {
            let p = list[k]
            let note = miss?.prompt == p.id ? miss?.text : nil
            let center = (CGFloat(k - first) + 0.5) * h
            VStack(alignment: .leading, spacing: 4) {
                Text(Pile.firstLine(p.text)).font(ui(12)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.tail)
                Text(note ?? (p.reply.isEmpty ? "…" : p.reply)).font(ui(11)).foregroundStyle(Color.inkFaint).lineLimit(3)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 320, alignment: .leading)
            .background(Color.paper)
            .overlay(Rectangle().stroke(Color.rule, lineWidth: 1))
            .alignmentGuide(.top) { d in -min(max(center - d.height / 2, Self.inset.top - top), height - top - 8 - d.height) }
            .offset(x: -(Self.width + 4))
            .allowsHitTesting(false)
        }
    }
}
