import AppKit
import Combine

extension Publisher {
    func tap(_ receiveOutput: @escaping (Output) -> Void) -> AnyPublisher<Output, Failure> {
        handleEvents(receiveOutput: { output in
            receiveOutput(output)
        })
        .eraseToAnyPublisher()
    }
}

extension Publisher {
    func mapTo<T>(_ value: T) -> AnyPublisher<T, Failure> {
        map { _ in value }
            .eraseToAnyPublisher()
    }
}

extension Publisher {
    typealias WithPrevious<T> = (previous: T?, current: T)

    /// Includes the current element as well as the previous element from the upstream publisher in a tuple where the previous element is optional.
    /// The first time the upstream publisher emits an element, the previous element will be `nil`.
    ///
    /// ```
    /// let range = (1...5)
    /// let subscription = range.publisher
    ///   .pairwise()
    ///   .sink { print("(\($0.previous), \($0.current))", terminator: " ") }
    /// ```
    /// Prints: "(nil, 1) (Optional(1), 2) (Optional(2), 3) (Optional(3), 4) (Optional(4), 5)".
    ///
    /// - Returns: A publisher of a tuple of the previous and current elements from the upstream publisher.
    ///
    /// - Note: Based on <https://stackoverflow.com/a/67133582/3532505>.
    func withPrevious() -> AnyPublisher<WithPrevious<Output>, Failure> {
        // `scan()` needs an initial value, which is `nil` in our case.
        // Therefore we have to return an optional here and use `compactMap()` below the remove the optional type.
        scan(nil) { previousPair, currentElement -> WithPrevious<Output>? in
            WithPrevious(previous: previousPair?.current, current: currentElement)
        }
        .compactMap { $0 }
        .eraseToAnyPublisher()
    }
}
