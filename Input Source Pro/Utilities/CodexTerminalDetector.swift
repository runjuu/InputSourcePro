import AppKit
import AXSwift

enum CodexTerminalDetector {
    static let bundleIdentifier = "com.openai.codex"

    private static let maxAncestorDepth = 16

    // xterm.js prefixes every class on the helper textarea, its container, and
    // its render layers with `xterm` (e.g. `xterm-helper-textarea`,
    // `xterm-screen`, `xterm-viewport`, `xterm-rows`, `xterm-cursor-layer`).
    // Matching this prefix on AXDOMClassList is both specific to xterm.js and
    // resilient to version changes. We deliberately avoid broad keywords like
    // `terminal` / `console` / `shell`, because Codex labels other panes with
    // those words, which caused the terminal input source to be applied to the
    // chat composer as well.
    private static let xtermClassPrefix = "xterm"

    static func isTerminalFocused(
        app: NSRunningApplication,
        focusedElement: UIElement?
    ) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier,
              let focusedElement
        else { return false }

        return hasXtermAncestor(focusedElement)
    }

    private static func hasXtermAncestor(_ focusedElement: UIElement) -> Bool {
        var element: UIElement? = focusedElement

        for _ in 0 ..< maxAncestorDepth {
            guard let current = element else { return false }

            if elementHasXtermClass(current) {
                return true
            }

            element = try? current.attribute(.parent)
        }

        return false
    }

    private static func elementHasXtermClass(_ element: UIElement) -> Bool {
        return element.domClassList().contains { $0.hasPrefix(xtermClassPrefix) }
    }
}
