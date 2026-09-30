import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class ScreenLockStateTests: XCTestCase {
    func testNearMouseSubscriberReceivesInitialUnlockedState() {
        let events = PassthroughSubject<Bool, Never>()
        let locked = IndicatorVM.screenLockStatePublisher(events: events.eraseToAnyPublisher())
        let enabled = CurrentValueSubject<Bool, Never>(true)
        var subscriptions = Set<AnyCancellable>()
        var isIdle: [Bool] = []
        var nearMouseIsActive: [Bool] = []

        Publishers.CombineLatest(locked, enabled)
            .map { isLocked, isEnabled in isLocked || isEnabled }
            .sink { isIdle.append($0) }
            .store(in: &subscriptions)

        Publishers.CombineLatest(enabled, locked)
            .map { isEnabled, isLocked in isEnabled && !isLocked }
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
        let events = PassthroughSubject<Bool, Never>()
        let locked = IndicatorVM.screenLockStatePublisher(events: events.eraseToAnyPublisher())
        let enabled = CurrentValueSubject<Bool, Never>(true)
        var subscriptions = Set<AnyCancellable>()
        let didLock = expectation(description: "Screen locked")
        let didUnlock = expectation(description: "Screen unlocked")
        var nearMouseIsActive: [Bool] = []

        locked
            .sink { if $0 { didLock.fulfill() } }
            .store(in: &subscriptions)

        events.send(true)
        await fulfillment(of: [didLock], timeout: 1)

        Publishers.CombineLatest(enabled, locked)
            .map { isEnabled, isLocked in isEnabled && !isLocked }
            .sink {
                nearMouseIsActive.append($0)
                if $0 { didUnlock.fulfill() }
            }
            .store(in: &subscriptions)

        XCTAssertEqual(nearMouseIsActive, [false])
        enabled.send(false)
        enabled.send(true)
        XCTAssertEqual(nearMouseIsActive, [false, false, false])

        events.send(false)
        await fulfillment(of: [didUnlock], timeout: 1)
        XCTAssertEqual(nearMouseIsActive, [false, false, false, true])
        subscriptions.removeAll()
    }
}
