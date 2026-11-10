import AppKit
import SwiftUI
import XCTest
@testable import Input_Source_Pro

final class ColorHexTests: XCTestCase {
    private func assertEightHexDigits(_ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(hex.range(of: "^[0-9a-f]{8}$", options: .regularExpression), hex, file: file, line: line)
    }

    func testGrayscaleIsConvertedToSRGB() {
        let hex = NSColor(white: 0.5, alpha: 1).hexWithAlpha
        assertEightHexDigits(hex)
        XCTAssertTrue(hex.hasSuffix("ff"))
        XCTAssertEqual(hex.prefix(2), hex.dropFirst(2).prefix(2))
        XCTAssertEqual(hex.dropFirst(2).prefix(2), hex.dropFirst(4).prefix(2))

        let roundTrip = NSColor(hex: hex).usingColorSpace(.sRGB)
        XCTAssertEqual(roundTrip?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func testBlackAndWhiteGrayscale() {
        XCTAssertEqual(NSColor(white: 0, alpha: 1).hexWithAlpha, "000000ff")
        XCTAssertEqual(NSColor(white: 1, alpha: 1).hexWithAlpha, "ffffffff")
    }

    func testCMYKIsNotFallbackString() {
        let hex = NSColor(deviceCyan: 0.2, magenta: 0.4, yellow: 0.6, black: 0.1, alpha: 1).hexWithAlpha
        assertEightHexDigits(hex)
    }

    func testSRGBIsUnchanged() {
        XCTAssertEqual(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).hexWithAlpha, "ff0000ff")
        XCTAssertEqual(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5).hexWithAlpha, "00ff007f")
        XCTAssertEqual(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5).hex, "00ff00")
    }

    func testDisplayP3IsConvertedAndClamped() {
        let hex = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1).hexWithAlpha
        assertEightHexDigits(hex)
        // Out-of-gamut green and blue clamp to zero instead of going negative.
        XCTAssertEqual(hex, "ff0000ff")
    }

    func testSwiftUIColorFromGrayscale() {
        let hex = Color(NSColor(white: 0.5, alpha: 1)).hexWithAlpha
        XCTAssertNotEqual(hex, "Color not RGB.")
        assertEightHexDigits(hex)
    }
}
