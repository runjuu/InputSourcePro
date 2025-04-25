import AppKit
import SwiftUI

extension NSColor {
    static let alignmentIndicator = NSColor(named: "AlignmentIndicatorColor")!

    static let fakeWindow = NSColor(named: "FakeWindowColor")!

    static let close = NSColor(named: "CloseColor")!

    static let maximise = NSColor(named: "MaximiseColor")!

    static let minimise = NSColor(named: "MinimiseColor")!

    static let background = NSColor(named: "Background")!

    static let background1 = NSColor(named: "Background1")!

    static let background2 = NSColor(named: "Background2")!

    static let border = NSColor(named: "BorderColor")!

    static let border2 = NSColor(named: "BorderColor2")!

    static let rainbow1 = NSColor(named: "Rainbow1")!

    static let rainbow2 = NSColor(named: "Rainbow2")!

    static let rainbow3 = NSColor(named: "Rainbow3")!

    static let rainbow4 = NSColor(named: "Rainbow4")!

    static let rainbow5 = NSColor(named: "Rainbow5")!

    static let rainbow6 = NSColor(named: "Rainbow6")!

    var color: Color {
        Color(self)
    }
}
