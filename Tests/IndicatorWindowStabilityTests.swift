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
            XCTAssertEqual(window.frame.origin, CGPoint(x: 585, y: 114))
            XCTAssertEqual(window.frame.width, capsLock ? 22 : 8, accuracy: 1)
        }
    }

    private func config(title: String) -> IndicatorViewConfig {
        IndicatorViewConfig(
            inputSource: InputSource.getCurrentInputSource(), kind: .title, size: .medium,
            bgColor: .black, textColor: .white,
            badge: .init(glyph: .symbol("globe"), title: title)
        )
    }
}
