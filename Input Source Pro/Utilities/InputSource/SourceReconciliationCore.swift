import Combine

/// Shared PRODUCTION reconciliation implementation, specialized with immutable test values
/// in the hostless SwiftPM XCTest target. This file is compiled into the app's target too.
/// No AppKit, TIS, preference store or timer is ever created here.
@MainActor
enum SourceReconciliationCore {
    struct Snapshot<Context, Source, Reason> {
        let appKind: Context?
        let inputSource: Source
        let inputSourceChangeReason: Reason
    }

    enum Action<Context, Source> {
        case start
        case appChanged(Context)
        case switchInputSourceByShortcut(Source)
        case inputSourceChanged(Source)
    }

    /// Serializes synchronous Combine effects through the complete downstream
    /// scan/dedup/Published assignment. Nested sends are FIFO admissions; no
    /// downstream callback occurs before the current subject.send returns.
    ///
    /// Safety contract: bounded admissions and per-drain deliveries. Reaching
    /// either limit enters a STICKY TERMINAL FAULT, rejecting further sends.
    /// Previously delivered effects are NOT rolled back; queued events after
    /// fault are NOT delivered. The onFault callback fires once after safe
    /// cleanup. No claim of durable, lossless delivery under fault/cancellation.
    /// A downstream subscriber which never returns cannot be preempted.
    @MainActor
    final class SerializedActionRelay<Event> {
        struct Limits {
            let maxQueued: Int
            let maxDeliveriesPerDrain: Int
            init(maxQueued: Int = 64, maxDeliveriesPerDrain: Int = 256) {
                precondition(maxQueued > 0 && maxDeliveriesPerDrain > 0)
                self.maxQueued = maxQueued
                self.maxDeliveriesPerDrain = maxDeliveriesPerDrain
            }
        }

        enum Fault: Equatable {
            case queuedLimit(Int)
            case deliveryLimit(Int)
        }

        enum Admission: Equatable {
            case accepted // admission, NOT a guarantee of effect completion
            case fault(Fault)
        }

        private let subject = PassthroughSubject<Event, Never>()
        private let limits: Limits
        private let onFault: @MainActor (Fault) -> Void
        private var pending: [Event] = []
        private var head = 0
        private var isDelivering = false
        private(set) var terminalFault: Fault?

        init(limits: Limits = Limits(), onFault: @escaping @MainActor (Fault) -> Void) {
            self.limits = limits
            self.onFault = onFault
        }

        var publisher: AnyPublisher<Event, Never> {
            subject.eraseToAnyPublisher()
        }

        @discardableResult
        func send(_ event: Event) -> Admission {
            if let fault = terminalFault { return .fault(fault) }
            // The processed prefix is not live backlog. Overflow must be a
            // visible terminal fault, not an unreported silent drop.
            if pending.count - head >= limits.maxQueued {
                let fault = Fault.queuedLimit(limits.maxQueued)
                terminalFault = fault
                return .fault(fault)
            }
            pending.append(event)
            guard !isDelivering else { return .accepted }
            drain()
            return terminalFault.map { .fault($0) } ?? .accepted
        }

        private func drain() {
            precondition(!isDelivering)
            isDelivering = true
            var deliveries = 0
            // Always finish retiring accepted payloads, including those admitted
            // by finalizers while previous storage is being destroyed. A fault
            // disables deliveries in the inner guard, NOT cleanup of new pending.
            while true {
                while head < pending.count && terminalFault == nil {
                    if deliveries >= limits.maxDeliveriesPerDrain {
                        terminalFault = .deliveryLimit(limits.maxDeliveriesPerDrain)
                        break
                    }
                    let next = pending[head]
                    head += 1
                    deliveries += 1
                    subject.send(next)
                }
                // A fault may also arise INSIDE retireStorage() via a finalizer.
                // Keep iterating until no accepted payload remains, even then.
                retireStorage()
                if pending.isEmpty { break }
            }
            isDelivering = false
            if let fault = terminalFault { onFault(fault) }
        }

        private func retireStorage() {
            // Copy/move the old buffer into a LOCAL holder before resetting
            // active storage. Payload deinit may synchronously call send();
            // that callback appends only to the NEW pending array, not the
            // array being mutated/released below. Keep isDelivering true.
            var retired = pending
            pending = []
            head = 0
            retired.removeAll(keepingCapacity: false)
            // All deinit-enqueued events are inspected by the enclosing drain.
        }
    }

    struct Dependencies<Context, Source, Reason> {
        let readActual: () -> Source
        let rule: (Context) -> (inputSource: Source, reason: Reason)?
        let select: (Source, Context?) -> Void
        let cache: (Context, Source) -> Void
        let noChanges: Reason
        let system: Reason
        let shortcut: Reason
    }

    /// Precisely mirrors R3 equality: source identity always matters, even at nil context.
    static func same<Context, Source: Equatable, Reason>(
        _ lhs: Snapshot<Context, Source, Reason>,
        _ rhs: Snapshot<Context, Source, Reason>,
        sameContext: (Context, Context) -> Bool
    ) -> Bool {
        guard lhs.inputSource == rhs.inputSource else { return false }
        switch (lhs.appKind, rhs.appKind) {
        case (nil, nil): return true
        case let (.some(a), .some(b)): return sameContext(a, b)
        default: return false
        }
    }

    /// R3's *single* reducer. No test-side copy of app/shortcut/poll branches.
    /// Effects deliberately retain R3 order: optional select, cache, output.
    static func reduce<Context, Source: Equatable, Reason>(
        _ state: Snapshot<Context, Source, Reason>,
        _ action: Action<Context, Source>,
        deps: Dependencies<Context, Source, Reason>
    ) -> Snapshot<Context, Source, Reason> {
        func update(_ context: Context?, _ source: Source, _ reason: Reason) -> Snapshot<Context, Source, Reason> {
            if let context = context { deps.cache(context, source) }
            return Snapshot(appKind: context, inputSource: source, inputSourceChangeReason: reason)
        }

        switch action {
        case .start:
            return state
        case let .appChanged(app):
            if let rule = deps.rule(app) {
                let actual = deps.readActual()
                if actual == rule.inputSource {
                    return update(app, actual, deps.noChanges)
                }
                deps.select(rule.inputSource, app)
                return update(app, rule.inputSource, rule.reason)
            }
            let actual = deps.readActual()
            let reason = actual == state.inputSource ? deps.noChanges : deps.system
            return update(app, actual, reason)
        case let .inputSourceChanged(source):
            guard source != state.inputSource else { return state }
            return update(state.appKind, source, deps.system)
        case let .switchInputSourceByShortcut(source):
            deps.select(source, state.appKind)
            return update(state.appKind, source, deps.shortcut)
        }
    }

    /// Actual Combine .scan -> final .removeDuplicates pipeline used by both clients.
    /// Dependencies are acquired PER ACTION through a weak-owner provider: when the
    /// owner is gone, R3's original scan returns its accumulator without effects.
    /// Contract: deliver all actions/tokens serially on MainActor. The actor on this
    /// factory does not itself reschedule asynchronous Combine publisher deliveries.
    /// Non-reentrant delivery is an R3 precondition; hostile feedback has its own test.
    static func states<Context, Source: Equatable, Reason>(
        actions: AnyPublisher<Action<Context, Source>, Never>,
        initial: Snapshot<Context, Source, Reason>,
        dependencies: @escaping () -> Dependencies<Context, Source, Reason>?,
        sameContext: @escaping (Context, Context) -> Bool
    ) -> AnyPublisher<Snapshot<Context, Source, Reason>, Never> {
        actions
            .scan(initial) { current, action in
                guard let deps = dependencies() else { return current }
                return reduce(current, action, deps: deps)
            }
            .removeDuplicates(by: { same($0, $1, sameContext: sameContext) })
            .eraseToAnyPublisher()
    }

    /// Every delivered token reads the source AT DELIVERY TIME. No pre-reducer dedup.
    static func observations<Source>(
        tokens: AnyPublisher<Void, Never>,
        readActual: @escaping () -> Source,
        observed: @escaping (Source) -> Void
    ) -> AnyPublisher<Source, Never> {
        tokens.map { _ in readActual() }
            .handleEvents(receiveOutput: observed)
            .eraseToAnyPublisher()
    }

    /// The heartbeat subscription is independent of select requests. Its owner
    /// MUST hold the returned cancellable; cancellation is handled by its deinit.
    static func connectHeartbeat(
        tokens: AnyPublisher<Void, Never>,
        deliver: @escaping () -> Void
    ) -> AnyCancellable {
        tokens.sink { _ in deliver() }
    }
}
