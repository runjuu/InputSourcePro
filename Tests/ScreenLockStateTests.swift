import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class ScreenLockStateTests: XCTestCase {
    private let didLock = Notification.Name("com.apple.screenIsLocked")
    private let didUnlock = Notification.Name("com.apple.screenIsUnlocked")

    func testNearMouseSubscriberReceivesInitialUnsuspendedState() {
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let enabled = CurrentValueSubject<Bool, Never>(true)
        var subscriptions = Set<AnyCancellable>()
        var isIdle: [Bool] = []
        var nearMouseIsActive: [Bool] = []

        Publishers.CombineLatest(suspended, enabled)
            .map { isSuspended, isEnabled in isSuspended || isEnabled }
            .sink { isIdle.append($0) }
            .store(in: &subscriptions)

        Publishers.CombineLatest(enabled, suspended)
            .map { isEnabled, isSuspended in isEnabled && !isSuspended }
            .sink { nearMouseIsActive.append($0) }
            .store(in: &subscriptions)

        XCTAssertEqual(isIdle, [true])
        XCTAssertEqual(nearMouseIsActive, [true])

        enabled.send(false)
        enabled.send(true)
        XCTAssertEqual(nearMouseIsActive, [true, false, true])
        subscriptions.removeAll()
    }

    func testLateSubscriberStaysInactiveUntilUnlock() async {
        let lockNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: lockNotificationCenter,
            workspaceNotificationCenter: NotificationCenter()
        )
        let enabled = CurrentValueSubject<Bool, Never>(true)
        var subscriptions = Set<AnyCancellable>()
        var nearMouseIsActive: [Bool] = []

        suspended
            .sink { _ in }
            .store(in: &subscriptions)

        lockNotificationCenter.post(name: didLock, object: nil)
        await drainMainQueue()

        Publishers.CombineLatest(enabled, suspended)
            .map { isEnabled, isSuspended in isEnabled && !isSuspended }
            .sink { nearMouseIsActive.append($0) }
            .store(in: &subscriptions)

        XCTAssertEqual(nearMouseIsActive, [false])
        enabled.send(false)
        enabled.send(true)
        XCTAssertEqual(nearMouseIsActive, [false, false, false])

        lockNotificationCenter.post(name: didUnlock, object: nil)
        await drainMainQueue()
        XCTAssertEqual(nearMouseIsActive, [false, false, false, true])
        subscriptions.removeAll()
    }

    func testNotificationsAreObservedOnTheirRespectiveCenters() async {
        let lockNotificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: lockNotificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        var states: [Bool] = []
        let subscription = suspended.sink { states.append($0) }

        lockNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotificationCenter.post(name: didLock, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false])

        lockNotificationCenter.post(name: didLock, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true])

        workspaceNotificationCenter.post(name: didUnlock, object: nil)
        lockNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true])

        lockNotificationCenter.post(name: didUnlock, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false, true])

        lockNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false, true])

        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false, true, false])
        subscription.cancel()
    }

    func testSleepAndWakeWhileUnlockedResumeMonitoringWithoutDuplicateStates() async {
        let workspaceNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: NotificationCenter(),
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        var states: [Bool] = []
        let subscription = suspended.sink {
            XCTAssertTrue(Thread.isMainThread)
            states.append($0)
        }

        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true])

        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false])
        subscription.cancel()
    }

    func testWakeWhileLockedStaysSuspendedUntilUnlock() async {
        let lockNotificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: lockNotificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        var states: [Bool] = []
        let subscription = suspended.sink { states.append($0) }

        lockNotificationCenter.post(name: didLock, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true])

        lockNotificationCenter.post(name: didUnlock, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false])
        subscription.cancel()
    }

    func testUnlockDuringSleepStaysSuspendedUntilWake() async {
        let lockNotificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: lockNotificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        var states: [Bool] = []
        let subscription = suspended.sink { states.append($0) }

        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        lockNotificationCenter.post(name: didLock, object: nil)
        lockNotificationCenter.post(name: didUnlock, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true])

        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [false, true, false])
        subscription.cancel()
    }

    func testLateSubscriberImmediatelyReceivesSleepingState() async {
        let workspaceNotificationCenter = NotificationCenter()
        let suspended = IndicatorVM.indicatorSuspensionPublisher(
            lockNotificationCenter: NotificationCenter(),
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        let firstSubscription = suspended.sink { _ in }

        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drainMainQueue()

        var states: [Bool] = []
        let lateSubscription = suspended.sink { states.append($0) }
        XCTAssertEqual(states, [true])

        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(states, [true, false])
        lateSubscription.cancel()
        firstSubscription.cancel()
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue delivered notification state changes")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }
}
