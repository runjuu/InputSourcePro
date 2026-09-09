import AppKit
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AppKindComparisonTests: XCTestCase {
    private let app = NSRunningApplication.current

    func testFocusedAddressBarCreatesBrowserInfoWithoutURL() {
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: nil,
            rule: nil,
            isFocusedOnAddressBar: true
        )

        XCTAssertNotNil(browserInfo)
        XCTAssertNil(browserInfo?.url)
        XCTAssertEqual(browserInfo?.isFocusedOnAddressBar, true)
    }

    func testMissingURLOutsideAddressBarDoesNotCreateBrowserInfo() {
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: nil,
            rule: nil,
            isFocusedOnAddressBar: false
        )

        XCTAssertNil(browserInfo)
    }

    func testFocusedAddressBarPreservesObservedPageURL() {
        let url = URL(string: "https://example.com/page")!
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: url,
            rule: nil,
            isFocusedOnAddressBar: true
        )

        XCTAssertEqual(browserInfo?.url, url)
    }

    func testAddressBarTextMutationDoesNotChangeContext() {
        let previous = browser(url: URL(string: "https://example.com")!, addressBarFocused: true)
        let current = browser(url: URL(string: "https://search.invalid/n")!, addressBarFocused: true)

        XCTAssertTrue(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testEnteringAddressBarChangesContextWhenDetectionIsEnabled() {
        let url = URL(string: "https://example.com")!
        let previous = browser(url: url, addressBarFocused: false)
        let current = browser(url: url, addressBarFocused: true)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testLeavingAddressBarChangesContextWhenDetectionIsEnabled() {
        let url = URL(string: "https://example.com")!
        let previous = browser(url: url, addressBarFocused: true)
        let current = browser(url: url, addressBarFocused: false)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testNavigationChangesContextOutsideAddressBar() {
        let previous = browser(url: URL(string: "https://example.com")!, addressBarFocused: false)
        let current = browser(url: URL(string: "https://example.com/next")!, addressBarFocused: false)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testNormalAndBrowserWithUnknownURLAreDifferentContexts() {
        let normal = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, windowId: nil)
        )
        let unknownBrowser = browser(url: nil, addressBarFocused: true)

        XCTAssertFalse(unknownBrowser.isSameAppOrWebsite(with: normal, detectAddressBar: true))
        XCTAssertFalse(normal.isSameAppOrWebsite(with: unknownBrowser, detectAddressBar: true))
    }

    func testNewTabURLDoesNotCreateWebsiteId() {
        let newTab = browser(url: .newtab, addressBarFocused: false)

        XCTAssertNil(newTab.getId())
    }

    func testInstanceCacheIdIncludesPid() {
        XCTAssertEqual(
            AppKind.instanceCacheId(bundleId: "com.jetbrains.clion", processIdentifier: 42_001),
            "com.jetbrains.clion#42001"
        )
        XCTAssertEqual(
            AppKind.instanceCacheId(bundleId: nil, processIdentifier: 7),
            "pid:7"
        )
    }

    func testNormalGetIdIsPerProcess() {
        let kind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let bundleId = app.bundleId() ?? app.bundleIdentifier
        XCTAssertEqual(
            kind.getId(),
            AppKind.instanceCacheId(bundleId: bundleId, processIdentifier: app.processIdentifier)
        )
    }

    func testNormalGetIdIncludesWindowToken() {
        let kind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w42")
        )
        let bundleId = app.bundleId() ?? app.bundleIdentifier
        let processId = AppKind.instanceCacheId(
            bundleId: bundleId,
            processIdentifier: app.processIdentifier
        )
        XCTAssertEqual(kind.getId(), "\(processId)#w42")
        XCTAssertEqual(kind.processInstanceCacheId(), processId)
    }

    func testDifferentWindowsAreDifferentContexts() {
        let windowA = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, windowId: "w1")
        )
        let windowB = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, windowId: "w2")
        )
        XCTAssertFalse(windowA.isSameAppOrWebsite(with: windowB, detectAddressBar: true))
        XCTAssertFalse(IndicatorVM.shouldSkipSameContextAppChange(previous: windowA, next: windowB))
        XCTAssertTrue(IndicatorVM.shouldSkipSameContextAppChange(previous: windowA, next: windowA))
        XCTAssertTrue(IndicatorVM.isSameProcessWindowChange(previous: windowA, next: windowB))
        XCTAssertFalse(IndicatorVM.isSameProcessWindowChange(previous: windowA, next: windowA))
    }

    func testSameBundleMultiInstanceAppliesCacheButNotSystemDefault() {
        let source = InputSource.getCurrentInputSource()

        XCTAssertTrue(
            IndicatorVM.shouldApplyAutoSwitchAcrossSameBundleInstances(
                status: .cached(source),
                forced: nil,
                isAddressBar: false
            )
        )
        XCTAssertFalse(
            IndicatorVM.shouldApplyAutoSwitchAcrossSameBundleInstances(
                status: .specified(source),
                forced: nil,
                isAddressBar: false
            )
        )
        XCTAssertTrue(
            IndicatorVM.shouldApplyAutoSwitchAcrossSameBundleInstances(
                status: .specified(source),
                forced: source,
                isAddressBar: false
            )
        )
        XCTAssertTrue(
            IndicatorVM.shouldApplyAutoSwitchAcrossSameBundleInstances(
                status: .specified(source),
                forced: nil,
                isAddressBar: true
            )
        )
    }

    func testIsSameBundleDifferentProcessRequiresDistinctPids() {
        let a = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        XCTAssertFalse(IndicatorVM.isSameBundleDifferentProcess(previous: a, next: a))
        XCTAssertFalse(IndicatorVM.isSameBundleDifferentProcess(previous: nil, next: a))
    }

    func testStableUserLayoutAcceptRequiresHold() {
        XCTAssertTrue(
            IndicatorVM.shouldAcceptStableUserLayout(
                stillSameProcess: true,
                liveMatchesCandidate: true,
                isEchoOfSessionApply: false
            )
        )
        XCTAssertFalse(
            IndicatorVM.shouldAcceptStableUserLayout(
                stillSameProcess: true,
                liveMatchesCandidate: false,
                isEchoOfSessionApply: false
            )
        )
        XCTAssertFalse(
            IndicatorVM.shouldAcceptStableUserLayout(
                stillSameProcess: false,
                liveMatchesCandidate: true,
                isEchoOfSessionApply: false
            )
        )
        XCTAssertFalse(
            IndicatorVM.shouldAcceptStableUserLayout(
                stillSameProcess: true,
                liveMatchesCandidate: true,
                isEchoOfSessionApply: true
            )
        )
    }

    func testWindowLeavePrefersPendingUserOverCommitted() {
        let decision = IndicatorVM.windowLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: "com.apple.keylayout.US",
            pendingAcceptCacheId: "com.jetbrains.CLion#1#w1",
            previousCacheId: "com.jetbrains.CLion#1#w1",
            exactDiskId: "com.apple.keylayout.RussianWin"
        )
        XCTAssertEqual(decision.layoutId, "com.apple.keylayout.US")
        XCTAssertEqual(decision.reason, "pending-user")
    }

    func testWindowLeaveKeepsCommittedWhenLiveIsFlapWithoutPending() {
        let decision = IndicatorVM.windowLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: nil,
            pendingAcceptCacheId: nil,
            previousCacheId: "com.jetbrains.CLion#1#w1",
            exactDiskId: "com.apple.keylayout.RussianWin"
        )
        XCTAssertEqual(decision.layoutId, "com.apple.keylayout.RussianWin")
        XCTAssertEqual(decision.reason, "committed")
    }

    func testWindowLeaveIgnoresPendingForOtherWindow() {
        let decision = IndicatorVM.windowLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: "com.apple.keylayout.US",
            pendingAcceptCacheId: "com.jetbrains.CLion#1#w2",
            previousCacheId: "com.jetbrains.CLion#1#w1",
            exactDiskId: "com.apple.keylayout.RussianWin"
        )
        XCTAssertEqual(decision.layoutId, "com.apple.keylayout.RussianWin")
        XCTAssertEqual(decision.reason, "committed")
    }

    func testProcessLeaveSavesPendingUser() {
        let decision = IndicatorVM.processLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: "com.apple.keylayout.US",
            pendingAcceptCacheId: "com.anthropic.claudefordesktop#1#w1",
            previousCacheId: "com.anthropic.claudefordesktop#1#w1",
            isApplyingLayout: false
        )
        XCTAssertEqual(decision?.layoutId, "com.apple.keylayout.US")
        XCTAssertEqual(decision?.reason, "pending-user")
    }

    func testProcessLeaveSavesLiveAheadWhenTISRacedFocus() {
        let decision = IndicatorVM.processLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: nil,
            pendingAcceptCacheId: nil,
            previousCacheId: "com.anthropic.claudefordesktop#1#w1",
            isApplyingLayout: false
        )
        XCTAssertEqual(decision?.layoutId, "com.apple.keylayout.US")
        XCTAssertEqual(decision?.reason, "live-ahead")
    }

    func testProcessLeaveSkipsWhenLiveMatchesCommitted() {
        let decision = IndicatorVM.processLeaveSaveDecision(
            liveId: "com.apple.keylayout.RussianWin",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: nil,
            pendingAcceptCacheId: nil,
            previousCacheId: "com.jetbrains.CLion#1#w1",
            isApplyingLayout: false
        )
        XCTAssertNil(decision)
    }

    func testProcessLeaveSkipsLiveAheadWhileApplying() {
        let decision = IndicatorVM.processLeaveSaveDecision(
            liveId: "com.apple.keylayout.US",
            committedId: "com.apple.keylayout.RussianWin",
            pendingAcceptLayoutId: nil,
            pendingAcceptCacheId: nil,
            previousCacheId: "com.jetbrains.CLion#1#w1",
            isApplyingLayout: true
        )
        XCTAssertNil(decision)
    }

    func testSameContextAppChangeIsSkipped() {
        let first = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let again = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, windowId: nil)
        )
        XCTAssertTrue(IndicatorVM.shouldSkipSameContextAppChange(previous: first, next: again))
        XCTAssertFalse(IndicatorVM.shouldSkipSameContextAppChange(previous: nil, next: first))

        let page = browser(url: URL(string: "https://example.com")!, addressBarFocused: false)
        let addressBar = browser(url: URL(string: "https://example.com")!, addressBarFocused: true)
        XCTAssertFalse(IndicatorVM.shouldSkipSameContextAppChange(previous: page, next: addressBar))
    }

    private func browser(url: URL?, addressBarFocused: Bool) -> AppKind {
        return .browser(
            app: app,
            info: (
                focusedElement: nil,
                isFocusOnInputContainer: true,
                url: url,
                rule: nil,
                isFocusedOnAddressBar: addressBarFocused
            )
        )
    }
}
