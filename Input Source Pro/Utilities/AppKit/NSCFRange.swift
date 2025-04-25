import Foundation

extension CFRange {
    init(range: NSRange) {
        self = CFRangeMake(range.location == NSNotFound ? kCFNotFound : range.location, range.length)
    }

    func cursorRange(offset: Int, value: String) -> NSRange {
        return NSRange(location: max(min(location + offset, value.count - 1), 0), length: 1)
    }
}

extension NSRange {
    init(range: CFRange) {
        self = NSMakeRange(range.location == kCFNotFound ? NSNotFound : range.location, range.length)
    }
}
