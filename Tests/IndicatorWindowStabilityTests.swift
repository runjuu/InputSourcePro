import AppKit
import SwiftUI
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

    func testPinnedIndicatorAlignsCompactContentInsteadOfHiddenLabelToPixels() throws {
        let controller = IndicatorViewController()
        let panel = FloatWindowController()
        panel.contentViewController = controller
        defer { panel.close() }
        let window = try XCTUnwrap(panel.window)
        XCTAssertFalse(NSScreen.screens.isEmpty)

        for screen in NSScreen.screens {
            let point = CGPoint(x: screen.frame.midX + 0.37, y: screen.frame.midY + 0.19)
            for capsLock in [false, true, false] {
                var configuration = config(title: "")
                configuration.badge = nil
                configuration.showsCapsLock = capsLock
                controller.prepare(config: configuration)
                controller.refresh(at: point, displayMode: .alwaysOn)
                let indicator = try XCTUnwrap(controller.alwaysOnView)
                let frame = window.frame
                let visibleFrame = window.convertToScreen(indicator.convert(indicator.bounds, to: nil))
                let pixels = screen.convertRectToBacking(visibleFrame)
                XCTAssertEqual(pixels.minX, pixels.minX.rounded(), accuracy: 0.001)
                XCTAssertEqual(pixels.minY, pixels.minY.rounded(), accuracy: 0.001)
                XCTAssertEqual(visibleFrame.midX, point.x, accuracy: 0.5 / screen.backingScaleFactor + 0.001)
                XCTAssertEqual(visibleFrame.minY, point.y, accuracy: 0.5 / screen.backingScaleFactor + 0.001)
                XCTAssertTrue(frame.contains(visibleFrame))

                controller.refresh(at: point, displayMode: .alwaysOn)
                let repeatedFrame = window.convertToScreen(indicator.convert(indicator.bounds, to: nil))
                XCTAssertEqual(repeatedFrame, visibleFrame)
            }
        }
    }

    func testPixelAlignedContentFitsWholePointWindowsOnBothSidesOfScreenOrigin() {
        for scale: CGFloat in [1, 2] {
            for origin in [CGPoint(x: 100.5, y: 200.5), CGPoint(x: -500.5, y: -100.5)] {
                for width: CGFloat in [8, 22] {
                    let pixelOrigin = CGPoint(
                        x: (origin.x * scale).rounded() / scale,
                        y: (origin.y * scale).rounded() / scale
                    )
                    let size = CGSize(width: width, height: 8)
                    let layout = PixelAlignedWindowLayout(origin: pixelOrigin, size: size)
                    XCTAssertEqual(layout.frame.minX, floor(layout.frame.minX))
                    XCTAssertEqual(layout.frame.minY, floor(layout.frame.minY))
                    let content = CGRect(origin: CGPoint(
                        x: layout.frame.minX + layout.contentOffset.x,
                        y: layout.frame.minY + layout.contentOffset.y
                    ), size: size)
                    XCTAssertEqual(content.origin, pixelOrigin)
                    XCTAssertTrue(layout.frame.contains(content))
                }
            }
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

@MainActor
private final class PresentationObservingPanel: NSPanel {
    var onDisplay: (() -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if flag { onDisplay?() }
        super.setFrame(frameRect, display: flag)
    }
}

@MainActor
final class IndicatorPreviewLayoutTests: XCTestCase {
    func testAppearancePreviewIsCenteredAndFitsItsContent() throws {
        for size in IndicatorSize.allCases {
            for kind: IndicatorKind in [.icon, .title, .iconAndTitle] {
                let hostingView = NSHostingView(rootView: ItemSection {
                    DumpIndicatorView(config: config(kind: kind, size: size))
                })
                hostingView.frame = CGRect(x: 0, y: 0, width: 500, height: 100)
                hostingView.layoutSubtreeIfNeeded()

                let preview = try XCTUnwrap(previews(in: hostingView).first)
                let content = try XCTUnwrap(preview.subviews.first)
                let frame = content.convert(content.bounds, to: hostingView)
                XCTAssertEqual(frame.midX, hostingView.bounds.midX, accuracy: 1)
                XCTAssertEqual(frame.midY, hostingView.bounds.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(preview.bounds.height, content.fittingSize.height)
                XCTAssertTrue(hostingView.bounds.contains(frame))
            }
        }
    }

    func testColorSchemeGridReservesHeightAndCentersEachPreview() throws {
        for size in IndicatorSize.allCases {
            let hostingView = NSHostingView(rootView:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())]) {
                    DumpIndicatorView(config: config(kind: .alwaysOn, size: size))
                    DumpIndicatorView(config: config(kind: .iconAndTitle, size: size))
                    Text("Always-On Indicator")
                    Text("Tooltip")
                }
                .padding(16)
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: 500, height: hostingView.fittingSize.height)
            hostingView.layoutSubtreeIfNeeded()

            let previews = previews(in: hostingView)
            XCTAssertEqual(previews.count, 2)
            for preview in previews {
                let content = try XCTUnwrap(preview.subviews.first)
                let frame = content.convert(content.bounds, to: hostingView)
                let columnCenter: CGFloat = frame.midX < 250 ? 131 : 369
                XCTAssertEqual(frame.midX, columnCenter, accuracy: 1)
                XCTAssertGreaterThanOrEqual(preview.bounds.height, content.fittingSize.height)
                XCTAssertTrue(hostingView.bounds.contains(frame))
            }
        }
    }

    func testPositionPreviewFitsAtEveryAlignment() throws {
        for alignment in IndicatorPosition.Alignment.allCases {
            let hostingView = NSHostingView(rootView:
                IndicatorAlignmentView(alignment: alignment) {
                    DumpIndicatorView(config: config(kind: .iconAndTitle, size: .large))
                        .fixedSize()
                        .padding(12)
                }
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: 500, height: 230)
            hostingView.layoutSubtreeIfNeeded()

            let preview = try XCTUnwrap(previews(in: hostingView).first)
            let content = try XCTUnwrap(preview.subviews.first)
            let frame = content.convert(content.bounds, to: hostingView)
            XCTAssertTrue(hostingView.bounds.insetBy(dx: 11, dy: 11).contains(frame), "\(alignment)")
            XCTAssertEqual(preview.bounds.width, content.fittingSize.width, accuracy: 1)
            XCTAssertEqual(preview.bounds.height, content.fittingSize.height, accuracy: 1)
            if alignment == .center {
                XCTAssertEqual(frame.midX, hostingView.bounds.midX, accuracy: 1)
                XCTAssertEqual(frame.midY, hostingView.bounds.midY, accuracy: 1)
            }
        }
    }

    private func previews(in view: NSView) -> [NSViewHoverable] {
        if let preview = view as? NSViewHoverable { return [preview] }
        return view.subviews.flatMap { previews(in: $0) }
    }

    private func config(kind: IndicatorKind, size: IndicatorSize) -> IndicatorViewConfig {
        IndicatorViewConfig(
            inputSource: InputSource.getCurrentInputSource(), kind: kind, size: size,
            bgColor: .black, textColor: .white,
            badge: .init(glyph: .symbol("globe"), title: "Pinyin – Simplified")
        )
    }
}
