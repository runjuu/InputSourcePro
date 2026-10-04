import AppKit
import XCTest
@testable import Input_Source_Pro

final class IndicatorWindowSelectionTests: XCTestCase {
    private let document = WindowInfo(bounds: CGRect(x: 0, y: 6, width: 1506, height: 943), layer: 0, number: 1)
    private let overlay = WindowInfo(bounds: CGRect(x: 560, y: 40, width: 65, height: 40), layer: 25, number: 2)

    func testInputMethodOverlayCannotReplaceDocumentAnchor() {
        for windows in [[document], [overlay, document], [document, overlay], [document]] {
            XCTAssertEqual(WindowInfo.preferred(in: windows, focusedBounds: nil)?.number, document.number)
        }
    }

    func testFocusedDocumentWinsEvenWhenOverlayUsesNormalLayer() {
        let normalLayerOverlay = WindowInfo(bounds: overlay.bounds, layer: 0, number: 2)
        XCTAssertEqual(
            WindowInfo.preferred(in: [normalLayerOverlay, document], focusedBounds: document.bounds)?.number,
            document.number
        )
    }

    func testSwitchingBetweenDocumentWindowsChangesTheAnchor() {
        let second = WindowInfo(bounds: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0, number: 3)
        let windows = [overlay, document, second]
        for focused in [document, second, document] {
            XCTAssertEqual(WindowInfo.preferred(in: windows, focusedBounds: focused.bounds)?.number, focused.number)
        }
    }

    func testFocusedDialogCanAnchorAboveItsParentDocument() {
        let dialog = WindowInfo(bounds: CGRect(x: 300, y: 300, width: 400, height: 200), layer: 8, number: 3)
        XCTAssertEqual(
            WindowInfo.preferred(in: [overlay, dialog, document], focusedBounds: dialog.bounds)?.number,
            dialog.number
        )
    }

    func testStaleAccessibilityBoundsFallBackToFrontmostNormalWindow() {
        XCTAssertEqual(
            WindowInfo.preferred(in: [overlay, document], focusedBounds: CGRect(x: 99, y: 99, width: 400, height: 300))?.number,
            document.number
        )
    }

    func testFloatingOnlyAppsStillHaveAnAnchorAndEmptyListsDoNot() {
        XCTAssertEqual(WindowInfo.preferred(in: [overlay], focusedBounds: nil)?.number, overlay.number)
        XCTAssertNil(WindowInfo.preferred(in: [], focusedBounds: document.bounds))
    }
}

@MainActor
final class IndicatorWindowLayoutTests: XCTestCase {
    func testPendingContentDoesNotResizeDisplayedLabelBeforePositionArrives() throws {
        let controller = IndicatorViewController()
        let panel = FloatWindowController()
        panel.contentViewController = controller
        defer { panel.close() }
        let window = try XCTUnwrap(panel.window)
        controller.prepare(config: config(title: "A"))
        controller.refresh(at: CGPoint(x: 600, y: 200))
        let originalView = controller.normalView
        let originalFrame = window.frame

        controller.prepare(config: config(title: "Pinyin – Simplified"))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.normalView === originalView)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertGreaterThan(try XCTUnwrap(controller.fittingSize).width, originalFrame.width)

        let size = try XCTUnwrap(controller.fittingSize)
        controller.refresh(at: CGPoint(x: originalFrame.maxX - ceil(size.width), y: 200))
        window.displayIfNeeded()
        XCTAssertFalse(controller.normalView === originalView)
        XCTAssertEqual(window.frame.maxX, originalFrame.maxX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, 200, accuracy: 1)
        XCTAssertEqual(window.frame.width, ceil(size.width), accuracy: 1)
    }

    func testRapidSupersedingContentKeepsRightEdgeAndVerticalPositionStable() throws {
        let controller = IndicatorViewController()
        let panel = FloatWindowController()
        panel.contentViewController = controller
        defer { panel.close() }
        let window = try XCTUnwrap(panel.window)

        for title in ["A", "Pinyin – Simplified", "US", "Pinyin – Simplified", "A"] {
            controller.prepare(config: config(title: "Superseded update"))
            let superseded = controller.nextNormalView
            controller.prepare(config: config(title: title))
            let expected = controller.nextNormalView
            let size = try XCTUnwrap(controller.fittingSize)
            controller.refresh(at: CGPoint(x: 800 - ceil(size.width), y: 200))
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            XCTAssertTrue(controller.normalView === expected)
            XCTAssertFalse(controller.normalView === superseded)
            XCTAssertEqual(window.frame.maxX, 800, accuracy: 1)
            XCTAssertEqual(window.frame.minY, 200, accuracy: 1)
        }
    }

    func testCapsLockResizingKeepsAlwaysOnIndicatorAtCaret() throws {
        let controller = AlwaysOnIndicatorWindowController()
        defer { controller.close() }
        controller.position = CGPoint(x: 585, y: 114)
        let window = try XCTUnwrap(controller.window)
        var config = config(title: "")
        config.badge = nil
        for capsLock in [false, true, false, true, false] {
            config.showsCapsLock = capsLock
            controller.update(config: config)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(window.frame.midX, 585)
            XCTAssertEqual(window.frame.minY, 114)
            XCTAssertEqual(window.frame.width, capsLock ? 22 : 8, accuracy: 1)
        }
    }

    func testCaretAppearanceIsAppliedBeforeWindowIsDisplayedAtNewPosition() {
        let controller = IndicatorViewController()
        let window = PresentationObservingPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        var config = config(title: "")
        config.badge = nil
        controller.prepare(config: config)
        controller.refresh(at: CGPoint(x: 600, y: 200))

        var displays = 0
        window.onDisplay = {
            displays += 1
            XCTAssertEqual(controller.normalView?.alphaValue, 0)
            XCTAssertEqual(controller.alwaysOnView?.alphaValue, 1)
        }
        controller.refresh(at: CGPoint(x: 200, y: 300), displayMode: .alwaysOn)
        XCTAssertGreaterThan(displays, 0)
        XCTAssertEqual(window.frame.minX + (controller.alwaysOnView?.fittingSize.width ?? 0) / 2, 200)
        XCTAssertEqual(window.frame.minY, 300)

        // A content refresh while pinned must not reintroduce the full label.
        config.showsCapsLock = true
        controller.prepare(config: config)
        controller.refresh(at: CGPoint(x: 220, y: 300), displayMode: .alwaysOn)
        XCTAssertEqual(controller.normalView?.alphaValue, 0)
        XCTAssertEqual(window.frame.minX + (controller.alwaysOnView?.fittingSize.width ?? 0) / 2, 220)

        window.onDisplay = {
            XCTAssertEqual(controller.normalView?.alphaValue, 1)
            XCTAssertEqual(controller.alwaysOnView?.alphaValue, 0)
        }
        controller.refresh(at: CGPoint(x: 600, y: 200), displayMode: .normal)
        XCTAssertEqual(window.frame.origin, CGPoint(x: 600, y: 200))
    }

    func testPinnedAppearanceSurvivesContentRefreshAndBadgeExpiry() {
        let controller = IndicatorViewController()
        var config = config(title: "")
        config.badge = nil
        controller.prepare(config: config)
        controller.showAlwaysOnView()

        config.showsCapsLock = true
        controller.prepare(config: config)
        controller.refresh()
        XCTAssertEqual(controller.normalView?.alphaValue, 0)
        XCTAssertEqual(controller.alwaysOnView?.alphaValue, 1)

        config.badge = .init(glyph: .symbol("globe"), title: "Function Keys")
        controller.prepare(config: config)
        controller.refresh()
        XCTAssertEqual(controller.normalView?.alphaValue, 1)
        XCTAssertEqual(controller.alwaysOnView?.alphaValue, 0)

        config.badge = nil
        controller.prepare(config: config)
        controller.refresh()
        XCTAssertEqual(controller.normalView?.alphaValue, 0)
        XCTAssertEqual(controller.alwaysOnView?.alphaValue, 1)
    }

    private func config(title: String) -> IndicatorViewConfig {
        IndicatorViewConfig(
            inputSource: InputSource.getCurrentInputSource(), kind: .title, size: .medium,
            bgColor: .black, textColor: .white,
            badge: .init(glyph: .symbol("globe"), title: title)
        )
    }
}

@MainActor
private final class PresentationObservingPanel: NSPanel {
    var onDisplay: (() -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if flag { onDisplay?() }
        super.setFrame(frameRect, display: flag)
    }
}
