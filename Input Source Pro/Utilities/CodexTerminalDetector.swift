import AppKit
import AXSwift

enum CodexTerminalDetector {
    static let bundleIdentifier = "com.openai.codex"

    private static let maxAncestorDepth = 16
    private static let terminalKeywords = ["terminal", "xterm", "pty", "console", "shell"]

    static func isTerminalFocused(
        app: NSRunningApplication,
        focusedElement: UIElement?
    ) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier,
              let focusedElement
        else { return false }

        return hasTerminalAccessibilityMarker(focusedElement)
    }

    private static func hasTerminalAccessibilityMarker(_ focusedElement: UIElement) -> Bool {
        var element: UIElement? = focusedElement

        for _ in 0 ..< maxAncestorDepth {
            guard let current = element else { return false }

            if elementLooksLikeTerminal(current) {
                return true
            }

            element = try? current.attribute(.parent)
        }

        return false
    }

    private static func elementLooksLikeTerminal(_ element: UIElement) -> Bool {
        let textValues = [
            element.safeString(attribute: .identifier),
            element.safeString(attribute: "AXDOMIdentifier"),
            element.safeString(attribute: .title),
            element.safeString(attribute: .description),
            element.safeString(attribute: "AXHelp"),
            element.safeString(attribute: "AXRoleDescription"),
        ]
        .compactMap { $0 }

        if textValues.contains(where: containsTerminalKeyword) {
            return true
        }

        return element.domClassList().contains(where: containsTerminalKeyword)
    }

    private static func containsTerminalKeyword(_ value: String) -> Bool {
        let value = value.lowercased()
        return terminalKeywords.contains { value.contains($0) }
    }
}
