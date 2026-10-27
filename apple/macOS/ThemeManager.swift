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
        let bg = Tone.paper.ns(dark: isDark)
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

    /// SF Mono: the brand has no monospace face, and Apple's own reads closest to Helvetica.
    static func termFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Subtle tint for ordinary text selection: ink at 14 % on paper, 22 % in the dark.
    var selectionTint: NSColor { Tone.ink.ns(dark: isDark).withAlphaComponent(isDark ? 0.22 : 0.14) }

    /// Loud highlight for find matches (they render as the selection).
    var findHighlight: NSColor { NSColor.systemYellow.withAlphaComponent(0.6) }

    func style(terminal: KnifeTermView) {
        let t = current
        terminal.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        // the 16 ANSI colours stay the terminal palette's; ink, paper and the cursor are the brand's
        terminal.nativeBackgroundColor = Tone.paper.ns(dark: isDark)
        terminal.nativeForegroundColor = Tone.ink.ns(dark: isDark)
        terminal.caretColor = Tone.ink.ns(dark: isDark)
        terminal.caretTextColor = Tone.paper.ns(dark: isDark)
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

/// Infinite Machine's tokens (Zach's desktop app): ink on paper, greys between, hairline rules, and
/// one colour — Electric Green, kept for the dot that says a tab is working or wants you. Each is a
/// light/dark pair; `Color.ink` and the rest resolve for the appearance they're drawn in, so auto
/// mode follows the system without a re-render.
struct Tone {
    let light: UInt32, dark: UInt32

    static let ink      = Tone(light: 0x000000, dark: 0xfefefe)
    static let inkSoft  = Tone(light: 0x676767, dark: 0xa6a6a6)
    static let inkFaint = Tone(light: 0x858789, dark: 0x858789)
    static let rule     = Tone(light: 0xe0e1e4, dark: 0x262626)
    static let paper    = Tone(light: 0xfefefe, dark: 0x000000)
    static let paper2   = Tone(light: 0xf5f5f5, dark: 0x0b0b0b)   // the sidebar
    static let paper3   = Tone(light: 0xeeeeee, dark: 0x171717)   // drop and hover fills
    static let live     = Tone(light: 0x00ff57, dark: 0x00ff57)

    func ns(dark: Bool) -> NSColor {
        let hex = dark ? self.dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                       blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    var ns: NSColor {
        NSColor(name: nil) { a in ns(dark: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    }
}

extension SwiftUI.Color {
    static let ink = Color(nsColor: Tone.ink.ns)
    static let inkSoft = Color(nsColor: Tone.inkSoft.ns)
    static let inkFaint = Color(nsColor: Tone.inkFaint.ns)
    static let rule = Color(nsColor: Tone.rule.ns)
    static let paper = Color(nsColor: Tone.paper.ns)
    static let paper2 = Color(nsColor: Tone.paper2.ns)
    static let paper3 = Color(nsColor: Tone.paper3.ns)
    static let live = Color(nsColor: Tone.live.ns)
}
