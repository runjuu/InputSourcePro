import Carbon
import XCTest
@testable import Input_Source_Pro

@MainActor
final class InputSourceDeduplicationTests: XCTestCase {
    func testCollapsesInputSourcesSharingPersistentIdentifier() {
        let tis = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let first = InputSource(tisInputSource: tis)
        let duplicate = InputSource(tisInputSource: tis)

        // Precondition: two InputSources wrapping the same TIS object share an identity.
        XCTAssertEqual(first.persistentIdentifier, duplicate.persistentIdentifier)

        let result = InputSource.deduplicatedByPersistentIdentifier([first, duplicate])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.persistentIdentifier, first.persistentIdentifier)
    }

    func testPreservesFirstOccurrenceOrderWhileDroppingDuplicates() throws {
        let unique = InputSource.sources
        try XCTSkipIf(unique.count < 2, "Need at least two distinct input sources for this test")

        // Interleave each source with a duplicate wrapping the same TIS object: [a, a, b, b, …].
        let withDuplicates = unique.flatMap { source in
            [source, InputSource(tisInputSource: source.tisInputSource)]
        }

        let result = InputSource.deduplicatedByPersistentIdentifier(withDuplicates)

        XCTAssertEqual(
            result.map(\.persistentIdentifier),
            unique.map(\.persistentIdentifier)
        )
    }
}
