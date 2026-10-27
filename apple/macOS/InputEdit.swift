/// What you've typed on the line a program is editing — a shell's prompt, Claude Code's input
/// box — as Knife saw it go out, so Shift+arrows can highlight it and ⌘X/⌘Z can edit it the way
/// a text field does. The program owns that line and only hears keystrokes, so every edit here
/// comes back as the keys a person would press: arrows to walk the cursor, Backspace to delete,
/// the text itself. The model starts empty wherever tracking began; anything already on the line
/// is the program's and is never selected, deleted or walked over.
///
/// Pure logic: KnifeTermView decides when tracking is safe, sends the keys, and checks the
/// screen agrees (`span`) before acting on any of it.
struct InputEdit {
    enum Key: Equatable {
        case left(Int), right(Int), backspace(Int), text(String)
    }

    private(set) var text: [Character] = []
    private(set) var cursor = 0          // where the program's cursor is, in characters of `text`
    private(set) var anchor: Int?        // the fixed end of a Shift+arrow highlight
    /// Bumps on every change except a highlight's moving end, so a screen check stays good
    /// while Shift+arrows walk within the row it saw.
    private(set) var revision = 0

    private struct State { var text: [Character]; var cursor: Int }
    private var undos: [State] = [], redos: [State] = []
    // The undo step still growing: typing joins a word at a time, Backspace/Delete runs together.
    private enum Run { case typing(Character), backspace, forwardDelete }
    private var run: Run?

    static let maxLength = 1000          // keeps a walk across the line to a sane burst of arrows
    static let maxUndo = 200

    var highlight: Range<Int>? {
        guard let a = anchor, a != cursor else { return nil }
        return min(a, cursor)..<max(a, cursor)
    }

    func string(_ r: Range<Int>) -> String { String(text[r]) }

    /// Characters the model can follow: one narrow scalar each, so one keystroke, one Backspace
    /// and one cell on screen. Combining marks, emoji, wide (CJK) text and control characters
    /// (newline, tab) are out — tracking stops rather than guess how the program counts them.
    static func typable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.count == s.count && s.unicodeScalars.allSatisfy {
            (0x20..<0x7f).contains($0.value) || ((0xa1..<0x300).contains($0.value) && $0.value != 0xad)
        }
    }

    // ─── Keys that go through to the program as they are ───

    /// A typed key or a paste the program is about to insert at its cursor. With `over` (a
    /// highlight) it returns the keys that delete that first; nil when the text can't be followed.
    mutating func insert(_ s: String, over r: Range<Int>?, typing: Bool) -> [Key]? {
        guard Self.typable(s), text.count - (r?.count ?? 0) + s.count <= Self.maxLength else { return nil }
        let chars = Array(s)
        var keys: [Key] = []
        if let r, !r.isEmpty {
            begin() // typing over a highlight undoes as one step with what replaced it
            keys = go(to: State(text: removing(r), cursor: r.lowerBound))
        } else if typing, case .typing(let last)? = run, !(last.isWhitespace && !chars[0].isWhitespace) {
            redos = []
        } else {
            begin()
        }
        text.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
        anchor = nil
        revision += 1
        run = typing ? .typing(chars[chars.count - 1]) : nil
        return keys
    }

    /// Backspace, which only stays followable while it deletes something Knife saw typed.
    mutating func backspace() -> Bool {
        guard cursor > 0 else { return false }
        if case .backspace? = run { redos = [] } else { begin() }
        cursor -= 1
        text.remove(at: cursor)
        anchor = nil
        revision += 1
        run = .backspace
        return true
    }

    mutating func forwardDelete() -> Bool {
        guard cursor < text.count else { return false }
        if case .forwardDelete? = run { redos = [] } else { begin() }
        text.remove(at: cursor)
        anchor = nil
        revision += 1
        run = .forwardDelete
        return true
    }

    /// A plain ← / →, followable while it stays inside the tracked text.
    mutating func move(by d: Int) -> Bool {
        guard (0...text.count).contains(cursor + d) else { return false }
        cursor += d
        anchor = nil
        revision += 1
        run = nil
        return true
    }

    // ─── Edits Knife makes on the program's behalf: each returns the keys to send ───

    /// Shift+arrow: move the highlight's free end to `target`.
    mutating func select(to target: Int) -> [Key] {
        if anchor == nil { anchor = cursor }
        run = nil
        return walk(to: max(0, min(text.count, target)))
    }

    /// ← / → on a highlight drop it at its start or end, as a text field does.
    mutating func collapse(toEnd: Bool) -> [Key] {
        let h = highlight
        anchor = nil
        run = nil
        revision += 1
        guard let h else { return [] }
        return walk(to: toEnd ? h.upperBound : h.lowerBound)
    }

    mutating func clearHighlight() { anchor = nil }

    /// Cut, or Backspace on a highlight: one undo step.
    mutating func remove(_ r: Range<Int>) -> [Key] {
        guard !r.isEmpty else { return [] }
        begin()
        run = nil
        return go(to: State(text: removing(r), cursor: r.lowerBound))
    }

    /// Back a step, or nil with nothing left (back to where tracking began).
    mutating func undo() -> [Key]? {
        guard let prev = undos.popLast() else { return nil }
        redos.append(State(text: text, cursor: cursor))
        run = nil
        return go(to: prev)
    }

    mutating func redo() -> [Key]? {
        guard let next = redos.popLast() else { return nil }
        undos.append(State(text: text, cursor: cursor))
        run = nil
        return go(to: next)
    }

    // ─── Reading the screen back ───

    /// Which tracked characters the cursor's row shows where they should be — `row` is that row's
    /// cells, `cursorCol` the program's cursor — or nil when it shows something else: the program
    /// took a key as something other than typing (a completion, a mode switch, a recalled line).
    /// Where the text wraps onto another row this row runs blank to its edge (a wrap, or Claude
    /// Code's indent), so the check stops there; the returned span is what's on this row.
    func span(row: [Character], cursorCol: Int) -> Range<Int>? {
        let col0 = cursorCol - cursor
        func cell(_ i: Int) -> Character? { (0..<row.count).contains(col0 + i) ? row[col0 + i] : nil }
        var lo = cursor, hi = cursor
        while lo > 0, let c = cell(lo - 1), c == text[lo - 1] { lo -= 1 }
        while hi < text.count, let c = cell(hi), c == text[hi] { hi += 1 }
        if lo > 0, cell(lo - 1) != nil, !row[..<(col0 + lo)].allSatisfy(Self.blank) { return nil }
        if hi < text.count, cell(hi) != nil, !row[(col0 + hi)...].allSatisfy(Self.blank) { return nil }
        // Nothing of a non-empty text in sight: the cursor isn't where the typing is.
        guard text.isEmpty || lo < hi else { return nil }
        return lo..<hi
    }

    /// The tracked characters a mouse selection over cells `cols` of the cursor's row covers,
    /// when it lies inside `span` — blank cells dragged past the end are let off. nil when it
    /// reaches the prompt, earlier output, or anything else that isn't yours to edit.
    func range(cols: Range<Int>, row: [Character], cursorCol: Int, within span: Range<Int>) -> Range<Int>? {
        let col0 = cursorCol - cursor
        let lo = cols.lowerBound - col0
        var hi = cols.upperBound - col0
        guard span.contains(lo) else { return nil }
        if hi > span.upperBound {
            let tail = (col0 + span.upperBound)..<min(cols.upperBound, row.count)
            guard tail.isEmpty || row[tail].allSatisfy(Self.blank) else { return nil }
            hi = span.upperBound
        }
        return lo < hi ? lo..<hi : nil
    }

    static func blank(_ c: Character) -> Bool { c == " " || c == "\u{0}" || c == "│" }

    /// The bytes a person's keyboard would send for `keys` (arrows follow DECCKM like SwiftTerm's).
    static func encode(_ keys: [Key], appCursor: Bool) -> String {
        keys.map { k -> String in
            switch k {
            case .left(let n): return String(repeating: appCursor ? "\u{1b}OD" : "\u{1b}[D", count: n)
            case .right(let n): return String(repeating: appCursor ? "\u{1b}OC" : "\u{1b}[C", count: n)
            case .backspace(let n): return String(repeating: "\u{7f}", count: n)
            case .text(let s): return s
            }
        }.joined()
    }

    // ─── ───

    private func removing(_ r: Range<Int>) -> [Character] {
        var t = text
        t.removeSubrange(r)
        return t
    }

    private mutating func begin() {
        undos.append(State(text: text, cursor: cursor))
        if undos.count > Self.maxUndo { undos.removeFirst() }
        redos = []
    }

    private mutating func walk(to c: Int) -> [Key] {
        let d = c - cursor
        cursor = c
        return d < 0 ? [.left(-d)] : d > 0 ? [.right(d)] : []
    }

    /// The keys that turn the line into `s`: walk to the end of what differs, Backspace over it,
    /// type what replaces it, then walk to `s`'s cursor.
    private mutating func go(to s: State) -> [Key] {
        var p = 0, q = 0
        while p < text.count, p < s.text.count, text[p] == s.text[p] { p += 1 }
        while q < text.count - p, q < s.text.count - p,
              text[text.count - 1 - q] == s.text[s.text.count - 1 - q] { q += 1 }
        var keys = walk(to: text.count - q)
        let gone = text.count - q - p
        if gone > 0 { keys.append(.backspace(gone)) }
        let typed = String(s.text[p..<(s.text.count - q)])
        if !typed.isEmpty { keys.append(.text(typed)) }
        cursor = p + typed.count
        text = s.text
        anchor = nil
        revision += 1
        for k in walk(to: s.cursor) {
            // fold back-to-back walks into one
            switch (keys.last, k) {
            case (.left(let a)?, .left(let b)): keys[keys.count - 1] = .left(a + b)
            case (.right(let a)?, .right(let b)): keys[keys.count - 1] = .right(a + b)
            case (.left(let a)?, .right(let b)): keys[keys.count - 1] = a > b ? .left(a - b) : .right(b - a)
            case (.right(let a)?, .left(let b)): keys[keys.count - 1] = a > b ? .right(a - b) : .left(b - a)
            default: keys.append(k)
            }
        }
        return keys.filter { $0 != .left(0) && $0 != .right(0) }
    }
}

/// Checks what each key actually sent against what following it assumed: the program heard
/// exactly that, or tracking has to end — Enter, ^C, Esc, ↑/↓, Tab, an IME that swallowed the key.
/// Outside a key, anything but a terminal report (focus, mouse, replies — all ESC-prefixed) is
/// typing Knife didn't model: text from the sidebar, a dropped file, a bracketed paste.
struct KeyWatch {
    private var out: [UInt8]?
    private var expected: [[UInt8]] = []

    /// A key arrives. Unless told otherwise it should send nothing (⌘T, a page scroll).
    mutating func begin() { out = []; expected = [[]] }
    mutating func expect(_ e: [[UInt8]]) { expected = e }

    /// Bytes on their way to the program; false when they end tracking.
    mutating func sent(_ data: ArraySlice<UInt8>) -> Bool {
        if out != nil { out! += data; return true }
        return data.first == 0x1b && !data.starts(with: Self.pasteStart)
    }

    /// The key has been dispatched: whether it sent what was expected, nil if no key was open.
    mutating func end() -> Bool? {
        guard let o = out else { return nil }
        out = nil
        return expected.contains(o)
    }

    static let pasteStart = Array("\u{1b}[200~".utf8), pasteEnd = Array("\u{1b}[201~".utf8)
    static func typed(_ s: String) -> [[UInt8]] { [Array(s.utf8)] }
    static func pasted(_ s: String, bracketed: Bool) -> [[UInt8]] {
        [bracketed ? pasteStart + Array(s.utf8) + pasteEnd : Array(s.utf8)]
    }
    static let backspace: [[UInt8]] = [[0x7f], [0x08]]
    static let forwardDelete: [[UInt8]] = [Array("\u{1b}[3~".utf8)]
    static func arrow(left: Bool) -> [[UInt8]] {
        left ? [Array("\u{1b}[D".utf8), Array("\u{1b}OD".utf8)] : [Array("\u{1b}[C".utf8), Array("\u{1b}OC".utf8)]
    }
}
