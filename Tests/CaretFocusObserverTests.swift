import AppKit
import AXSwift
import XCTest
@testable import Input_Source_Pro

@MainActor
final class CaretFocusObserverTests: XCTestCase {
    func testInvalidProcessIDsNeverConnectAndValidProcessCanRecover() async {
        for pid: pid_t in [-1, 0, .min] {
            let connectedToInvalidProcess = expectation(description: "Invalid PID must not connect")
            connectedToInvalidProcess.isInverted = true
            let recovered = expectation(description: "Valid process is observed")
            let observer = CaretFocusObserver(connect: { processID, _ in
                if processID != 42 { connectedToInvalidProcess.fulfill() }
                return CaretFocusObserver.Connection(read: {
                    CaretFocusObserver.Focus(element: nil, state: .input)
                }, stop: {})
            }, onChange: { update in
                guard update.pid == 42 else {
                    XCTFail("Invalid PID must not publish focus")
                    return
                }
                XCTAssertEqual(update.generation, 2)
                recovered.fulfill()
            })

            observer.watch(pid: pid, generation: 1)
            await fulfillment(of: [connectedToInvalidProcess], timeout: 0.35)
            observer.watch(pid: 42, generation: 2)
            await fulfillment(of: [recovered], timeout: 2)
            withExtendedLifetime(observer) {}
        }
    }

    func testInvalidProcessIDDisconnectsPreviousObserver() async {
        let delivered = expectation(description: "Initial focus delivered")
        let stopped = expectation(description: "Previous observer stopped on its worker")
        let invalidConnection = expectation(description: "Invalid PID must not reconnect")
        invalidConnection.isInverted = true
        let observer = CaretFocusObserver(connect: { pid, _ in
            guard pid == 42 else {
                invalidConnection.fulfill()
                throw AXError.illegalArgument
            }
            let owner = Thread.current
            return CaretFocusObserver.Connection(read: {
                CaretFocusObserver.Focus(element: nil, state: .input)
            }, stop: {
                XCTAssertTrue(Thread.current === owner)
                stopped.fulfill()
            })
        }, onChange: { update in
            XCTAssertEqual(update.pid, 42)
            delivered.fulfill()
        })

        observer.watch(pid: 42, generation: 1)
        await fulfillment(of: [delivered], timeout: 2)
        observer.watch(pid: -1, generation: 2)
        await fulfillment(of: [stopped], timeout: 2)
        await fulfillment(of: [invalidConnection], timeout: 0.35)
        withExtendedLifetime(observer) {}
    }

    func testInvalidProcessIDDiscardsPendingRead() async {
        let reading = expectation(description: "Old process focus read started")
        let stopped = expectation(description: "Old process disconnected")
        let releaseRead = DispatchSemaphore(value: 0)
        let observer = CaretFocusObserver(connect: { pid, _ in
            XCTAssertEqual(pid, 42)
            return CaretFocusObserver.Connection(read: {
                reading.fulfill()
                XCTAssertEqual(releaseRead.wait(timeout: .now() + 5), .success)
                return CaretFocusObserver.Focus(element: nil, state: .input)
            }, stop: { stopped.fulfill() })
        }, onChange: { _ in
            XCTFail("An invalidated process must not deliver stale focus")
        })

        observer.watch(pid: 42, generation: 1)
        await fulfillment(of: [reading], timeout: 2)
        observer.watch(pid: -1, generation: 2)
        releaseRead.signal()
        await fulfillment(of: [stopped], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testInvalidProcessIDCancelsPendingConnectionRetry() async {
        let failed = expectation(description: "Initial connection failed")
        let reconnected = expectation(description: "Neither old nor invalid PID may reconnect")
        reconnected.isInverted = true
        var attempts = 0
        let observer = CaretFocusObserver(connect: { pid, _ in
            attempts += 1
            if attempts > 1 || pid != 42 { reconnected.fulfill() }
            throw AXError.cannotComplete
        }, onChange: { update in
            XCTAssertEqual(update.pid, 42)
            XCTAssertEqual(update.state, .unavailable)
            failed.fulfill()
        })

        observer.watch(pid: 42, generation: 1)
        await fulfillment(of: [failed], timeout: 2)
        observer.watch(pid: -1, generation: 2)
        await fulfillment(of: [reconnected], timeout: 0.6)
        withExtendedLifetime(observer) {}
    }

    func testAXSwiftFailedCreationThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(try AXSwift.Observer(processID: -1) { _, _, _ in }) { error in
            XCTAssertEqual(error as? AXError, .illegalArgument)
        }
    }

    func testAXSwiftFailedCreationWithInfoThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(try AXSwift.Observer(processID: -1) { _, _, _, _ in }) { error in
            XCTAssertEqual(error as? AXError, .illegalArgument)
        }
    }
}
