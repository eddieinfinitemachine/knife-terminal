import AppKit
import SwiftUI
import SwiftTerm
import KnifeKit

enum ThemeMode: String, CaseIterable { case auto, light, dark }

@MainActor
final class ThemeManager: ObservableObject {
    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme"); apply() }
    }
    /// View › Bigger/Smaller Text: one point size for every terminal in every window.
    @Published var textSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(textSize), forKey: "textSize"); restyleAll() }
    }
    static let defaultTextSize: CGFloat = 13
    static let textSizes: ClosedRange<CGFloat> = 9...24
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        mode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "auto") ?? .auto
        let saved = CGFloat(UserDefaults.standard.double(forKey: "textSize")) // 0 when never set
        textSize = saved == 0 ? Self.defaultTextSize : Self.clamped(saved)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.restyleAll() }
        }
    }

    var isDark: Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .auto: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var current: TermTheme { isDark ? .dark : .light }

    func cycle() {
        mode = switch mode { case .auto: .light; case .light: .dark; case .dark: .auto }
    }

    func stepTextSize(_ delta: CGFloat) { textSize = Self.clamped(textSize + delta) }
    private static func clamped(_ s: CGFloat) -> CGFloat { min(max(s, textSizes.lowerBound), textSizes.upperBound) }

    /// The chat view's text follows the terminal's size, in proportion.
    var textScale: CGFloat { textSize / Self.defaultTextSize }

    func apply() {
        NSApp.appearance = switch mode {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        restyleAll()
    }

    func restyleAll() {
        let bg = nsColor(current.background)
        for wc in AppModel.shared.windows {
            wc.window?.backgroundColor = bg
            for tab in wc.tabs { style(terminal: tab.view) }
        }
        for m in AppModel.shared.minis {
            m.window?.backgroundColor = bg
            style(terminal: m.term)
        }
        AppModel.shared.objectWillChange.send()
    }

    func nsColor(_ c: TermTheme.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    var accent: NSColor { nsColor(current.accent) }
    var attention: NSColor { nsColor(current.attention) }
    var accentColor: SwiftUI.Color { Color(nsColor: accent) }
    var attentionColor: SwiftUI.Color { Color(nsColor: attention) }

    static func termFont(size: CGFloat) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "Space Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Subtle tint for ordinary text selection.
    var selectionTint: NSColor { nsColor(current.foreground).withAlphaComponent(isDark ? 0.18 : 0.15) }

    /// Loud highlight for find matches (they render as the selection).
    var findHighlight: NSColor { NSColor.systemYellow.withAlphaComponent(0.6) }

    func style(terminal: KnifeTermView) {
        let t = current
        terminal.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        terminal.nativeBackgroundColor = nsColor(t.background)
        terminal.nativeForegroundColor = nsColor(t.foreground)
        terminal.caretColor = nsColor(t.cursor)
        terminal.selectedTextBackgroundColor = terminal.findBarVisible ? findHighlight : selectionTint
        // A new font re-fits the grid and resizes the pty (and soft-resets the terminal and drops the
        // selection), so only on a real change — not on every theme flip.
        let font = Self.termFont(size: textSize)
        if terminal.font != font {
            terminal.font = font
            terminal.scheduleLinkScan() // link underlines sit on the old grid until rescanned
        }
        terminal.refreshLinkOverlay()
        terminal.needsDisplay = true
    }
}
