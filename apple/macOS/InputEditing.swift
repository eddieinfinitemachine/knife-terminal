import AppKit
import SwiftTerm

// ─── Editing what you've typed, as in a text field (the model is InputEdit) ───
// Shift+←/→/↑/↓/Home/End highlight it; typing, Backspace or ⌘X replace or remove the highlight (or
// a mouse selection inside it); ⌘C copies it; ⌘Z/⌘⇧Z undo and redo back to where the input
// started. Only while a line editor reads keys raw on the primary screen, and only on what the
// screen has just confirmed. Whatever Knife can't follow — Enter, ^C, Esc, ↑/↓, Tab, a click,
// text from the sidebar — ends tracking, and keys go through as before.
extension KnifeTermView {
    struct Editing {
        var input: InputEdit?
        var seen: (revision: Int, span: Range<Int>, row: Int, col0: Int)? // last look at the screen
        var seenFresh = false            // no output since that look
        let layer = CAShapeLayer()       // the highlight, drawn over the cells
        var watch = KeyWatch()           // what each key sent vs. what the model assumed
        var sendingEdit = false
        var check: DispatchWorkItem?
    }

    /// Runs a key past `handle`, noting what it sends on its way to the program; once AppKit has
    /// dispatched it, keyDone checks that against what following it assumed.
    func watchingKey(_ handle: () -> NSEvent?) -> NSEvent? {
        keyDone() // one AppKit hasn't let us settle yet
        editing.watch.begin()
        let result = handle()
        DispatchQueue.main.async { [weak self] in self?.keyDone() }
        return result
    }

    /// True when the key was handled here. Keys that go through are noted in the model first.
    func editKey(_ event: NSEvent, _ mods: NSEvent.ModifierFlags) -> Bool {
        guard lineEditorReading else { dropInput(); return false }
        let code = event.keyCode
        // ← → ↑ Home ↓ End. ↑/↓ select to the start/end rather than sending ↑/↓, which would
        // step through history.
        if mods == [.shift], let dir = [123: -1, 124: 1, 126: -2, 115: -2, 125: 2, 119: 2][code] {
            guard var m = editing.input else { return false }     // nothing typed yet: as before
            guard let span = confirmedSpan() else { return true } // screen hasn't caught up: hold it
            let target = abs(dir) == 1 ? m.cursor + dir : dir < 0 ? span.lowerBound : span.upperBound
            sendEdit(m.select(to: min(max(target, span.lowerBound), span.upperBound)))
            editing.input = m
            paintHighlight()
            return true
        }
        if mods == [.command] || mods == [.command, .shift] {
            switch (event.charactersIgnoringModifiers?.lowercased(), mods.contains(.shift)) {
            case ("c", false):
                guard let m = editing.input, m.highlight != nil, let r = editRange() else { return false }
                clip(m.string(r)) // the highlight stays, as in a text field
                return true
            case ("x", false):
                guard var m = editing.input, let r = editRange() else { return false }
                clip(m.string(r))
                sendEdit(m.remove(r))
                editing.input = m
                selectNone()
                return true
            case ("z", let redo):
                guard var m = editing.input, confirmedSpan() != nil,
                      let keys = redo ? m.redo() : m.undo() else { return false }
                sendEdit(keys)
                editing.input = m
                return true
            case ("v", false):
                if let s = NSPasteboard.general.string(forType: .string) { willInsert(s, typing: false) } else { dropInput() }
                return false
            default:
                return false
            }
        }
        if mods.subtracting(.shift).isEmpty, !hasMarkedText(), let s = event.characters, InputEdit.typable(s) {
            willInsert(s, typing: true)
            return false
        }
        if mods.isEmpty, code == 51 || code == 117 { // Backspace, forward Delete
            guard var m = editing.input else { return false }
            if let r = editRange() {
                sendEdit(m.remove(r))
                editing.input = m
                selectNone()
                return true
            }
            // a selection elsewhere gets the old erase-on-the-input-row (handleKey)
            guard !selection.active, code == 51 ? m.backspace() : m.forwardDelete() else { dropInput(); return false }
            editing.input = m
            editing.watch.expect(code == 51 ? KeyWatch.backspace : KeyWatch.forwardDelete)
            return false
        }
        if mods.isEmpty, code == 123 || code == 124 { // ←, →
            guard var m = editing.input else { return false }
            if m.highlight != nil {
                sendEdit(m.collapse(toEnd: code == 124))
                editing.input = m
                return true
            }
            guard m.move(by: code == 123 ? -1 : 1) else { dropInput(); return false }
            editing.input = m
            editing.watch.expect(KeyWatch.arrow(left: code == 123))
            return false
        }
        return false
    }

    /// Everything bound for the program passes here (see KeyWatch).
    func noteSent(_ data: ArraySlice<UInt8>) {
        if !editing.sendingEdit, !editing.watch.sent(data) { dropInput() }
    }

    /// Output can move the input (Claude Code's box shifts as a reply streams in): look again so
    /// the highlight follows. A look mid-redraw that doesn't agree just waits for the quiet one.
    func inputOutputArrived() {
        guard editing.input != nil else { return }
        editing.seenFresh = false
        _ = lookAtInput()
        paintHighlight()
        scheduleInputCheck()
    }

    /// A press ends the highlight, as in a text field. Where the program reads the mouse, the press
    /// is its own and may move its cursor.
    func inputMouseDown() {
        editing.input?.clearHighlight()
        paintHighlight()
        if allowMouseReporting && getTerminal().mouseMode != .off { dropInput() }
    }

    func dropInput() {
        guard editing.input != nil else { return }
        editing.input = nil
        editing.seen = nil
        paintHighlight()
    }

    // ─── ───

    private func keyDone() {
        guard let agreed = editing.watch.end() else { return }
        if !agreed { dropInput() } // the program heard something the model didn't
        paintHighlight()
        scheduleInputCheck()
    }

    /// A key that goes through and inserts `s` at the program's cursor (typing, ⌘V): delete what's
    /// highlighted first, then expect exactly `s` to go out.
    private func willInsert(_ s: String, typing: Bool) {
        var m = editing.input ?? InputEdit() // the input starts here if it isn't tracked yet
        let over = editing.input == nil ? nil : editRange()
        guard let keys = m.insert(s, over: over, typing: typing) else { dropInput(); return }
        if over != nil { selectNone() }
        sendEdit(keys)
        editing.input = m
        editing.watch.expect(typing ? KeyWatch.typed(s) : KeyWatch.pasted(s, bracketed: getTerminal().bracketedPasteMode))
    }

    /// A line editor (zsh, readline, Claude Code) reads keys raw; a running command reading whole
    /// lines, or a full-screen program, isn't a line Knife can edit for you.
    private var lineEditorReading: Bool {
        guard !getTerminal().isCurrentBufferAlternate, let fd = process?.childfd, fd >= 0 else { return false }
        var tio = termios()
        return tcgetattr(fd, &tio) == 0 && tio.c_lflag & tcflag_t(ICANON) == 0
    }

    /// The cursor's row, while the view shows the live screen.
    private func cursorRow() -> (cells: [Character], row: Int, col: Int)? {
        let t = getTerminal(), c = t.getCursorLocation()
        guard !canScroll || scrollPosition >= 1, c.x < t.cols, let line = t.getLine(row: c.y) else { return nil }
        return ((0..<t.cols).map { line[$0].getCharacter() }, c.y, c.x)
    }

    /// Read the screen back: true when it shows the tracked text where the model says (noted in
    /// `seen`), false when it shows something else, nil when it can't be seen.
    private func lookAtInput() -> Bool? {
        guard let m = editing.input, let r = cursorRow() else { return nil }
        guard let span = m.span(row: r.cells, cursorCol: r.col) else { return false }
        editing.seen = (m.revision, span, r.row, r.col - m.cursor)
        editing.seenFresh = true
        return true
    }

    /// The tracked text's span on the cursor's row, looking again if anything changed since.
    private func confirmedSpan() -> Range<Int>? {
        guard let m = editing.input else { return nil }
        if !editing.seenFresh || editing.seen?.revision != m.revision, lookAtInput() != true { return nil }
        return editing.seen?.span
    }

    /// What ⌘X, Backspace and typing act on: the Shift+arrow highlight, or a mouse selection on the
    /// cursor's row inside the tracked text. Elsewhere a selection is only for copying.
    private func editRange() -> Range<Int>? {
        guard let m = editing.input, let span = confirmedSpan() else { return nil }
        if let h = m.highlight { return h.clamped(to: span) == h ? h : nil }
        let t = getTerminal()
        guard selection.active, !selection.isMultiLine, let r = cursorRow(),
              selection.start.row - t.getTopVisibleRow() == r.row else { return nil }
        let (a, b) = (selection.start.col, selection.end.col) // the cells SwiftTerm draws
        let cols = a < b ? a..<(b == t.cols - 1 ? t.cols : b) : b..<a
        return m.range(cols: cols, row: r.cells, cursorCol: r.col, within: span)
    }

    /// The highlight is an overlay where the last look saw the text — not the terminal's own
    /// selection, which SwiftTerm clears on every write (each echo of an arrow would wipe it).
    private func paintHighlight() {
        let overlay = editing.layer
        var rect: CGRect?
        if let m = editing.input, let h = m.highlight, let s = editing.seen,
           s.revision == m.revision, h.clamped(to: s.span) == h {
            let (w, ch) = cellSize()
            rect = CGRect(x: CGFloat(s.col0 + h.lowerBound) * w, y: frame.height - CGFloat(s.row + 1) * ch,
                          width: CGFloat(h.count) * w, height: ch)
        }
        guard rect != nil || overlay.path != nil else { return }
        if overlay.superlayer !== layer {
            wantsLayer = true
            overlay.zPosition = 9 // under the link underlines
            layer?.addSublayer(overlay)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = layer?.bounds ?? bounds
        overlay.fillColor = AppModel.shared.theme.selectionTint.cgColor
        overlay.path = rect.map { CGPath(rect: $0, transform: nil) }
        CATransaction.commit()
    }

    /// Keys for an edit Knife makes, sent past the check on what keys send.
    private func sendEdit(_ keys: [InputEdit.Key]) {
        guard !keys.isEmpty else { return }
        editing.sendingEdit = true
        defer { editing.sendingEdit = false }
        send(txt: InputEdit.encode(keys, appCursor: getTerminal().applicationCursor))
    }

    private func clip(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        AppModel.shared.clips.add(s)
    }

    /// Once output goes quiet, look again: a program that took a key as something other than
    /// typing (a completion, a mode switch) or redrew the line ends tracking here.
    private func scheduleInputCheck() {
        guard editing.input != nil else { return }
        editing.check?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.editing.input != nil else { return }
            if !self.lineEditorReading || self.lookAtInput() == false { self.dropInput() }
            self.paintHighlight()
        }
        editing.check = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: check)
    }
}
